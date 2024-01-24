defmodule Electric.Satellite.Permissions do
  @moduledoc """
  Provides functions for validating writes from satellites and filtering reads from pg against a
  set of permissions.

  A `#{inspect(__MODULE__)}` struct is generated from a set of protobuf permissions definitions --
  a list of `SatPerms.Grant` structs direct from the DDLX ingest, and a list of `SatPerms.Role`
  structs generated by the DDLX assign triggers.

  The protobuf data is compiled into a set of lookup tables to make permissions checks as
  performant as possible.

  ## Key data structures

  - `Permissions.roles`: a map of `{relation(), privilege()} => assigned_roles()` which allows for
    a quick retrieval of all grants and associated roles for a given action.

    An example might look like:

    ```
    %{
      {{"public", "issues"}, :UPDATE} => %{
        scoped: [
          %Permissions.RoleGrant{role: %Permissions.Role{}, grant: %Permissions.Grant{}},
          %Permissions.RoleGrant{...}
        ],
        unscoped: [
          %Permissions.RoleGrant{role: %Permissions.Role{}, grant: %Permissions.Grant{}},
          %Permissions.RoleGrant{...}
        ]
      },
      {{"public", "issues"}, :INSERT} => %{
        scoped: [
          %Permissions.RoleGrant{...}
        ],
        unscoped: [
          %Permissions.RoleGrant{...}
        ]
      }
      # etc
    }
    ```

    Compiling this lookup table is the main job of the `update/3` function.

  - `%RoleGrant{}`: this struct holds a role and grant where the role provides the grant and the
    grant provides the rights.

  - `assigned_roles()`: A set of scoped and unscoped `RoleGrant` structs. "Unscoped" means that
    the role assignment applies globally and is not rooted on any element of the data.

  ## Applying permissions

  The DDLX system defines a user's roles via `ELECTRIC ASSIGN` statements and then grants those
  roles rights via `ELECTRIC GRANT` statements.

  We translate those `ASSIGN` and `GRANT` statements to actual permissions by first finding which
  roles a user has that apply to the change (insert, update, delete) in question and then
  validating that the grants for those roles allow the change.

  ## Validating writes

  The `validate_write/2` function takes a `Permissions` struct and a transaction and verifies that
  all the writes in the transaction are allowed according to the current permissions rules.

  If any change in the transaction fails the permissions check then the whole transaction is
  rejected.

  The permissions resolution process goes something like this:

  ### 1. Find scoped and unscoped `RoleGrant` instances for the change

  The `assigned_roles()` table is retrieved from the `Permissions.roles` attribute for the given
  change. This allows for quick verification that the user has some kind of permission to perform
  the action.

  If the `assigned_roles()` for a change is `nil` then we know immediately that the user does not
  have the right to make the given change and can bail immediately and return an error.

  Once we have a set of scoped and unscoped roles for a change, then we can test each one to check
  that the role applies to the change (always in the case of unscoped roles, depending on the
  change's position in the data for scoped roles) then test that any conditions on the grant are
  met.

  If the `assigned_roles()` table has any unscoped grants then we can jump to verifying that at
  least one of the grant rules allows for the change (see "Verifying Grants").

  If no unscoped roles/grants match the change or none of the unscoped grant rules allow the
  change then we try to find scoped roles for the change.

  ### 2. Match roles to the scope of the change

  The `Permissions.scope_resolver` attribute provides an implementation of the `Permissions.Scope`
  behaviour. This allows for traversing the tree and finding the associated scope root entry for
  any node.

  With this we can match a change to a set of scoped roles and then verify their associated
  grants.

  ### 3. Look for applicable transient permissions

  If no scoped roles match the change then there might be a matching transient permission. We find
  these by supplying the list of (scoped) Roles we have to the `Transient.for_roles/3` lookup
  function which will match the role's DDLX assignment id and the id of its scope root to the set
  of transient permissions available.

  For every transient permission we have access to, we can then verify the grants for the
  associated role.

  ### 4. Verifying Grants

  Grants can limit the allowed changes by:

  - They can limit the columns allowed. So e.g. you can `GRANT UPDATE (title) ON table TO role` to
    only allow `role` to update the `title` column of a table.

    With a grant of this style if you attempt to write to any other column, the write will be
    rejected.

  - They can have an optional `CHECK` expression that tests the content of the change against some
    function and will reject the write if that check fails.

  ### 5. Allowing the write

  Because the permissions system is at the moment additive, if *any* of the grants succeeds then
  the write is allowed.

  If no role-grant pairs are found that match the change or the conditions on all the matching
  grants fail, then the write is denied and the entire transaction is rejected.

  ### Special cases

  1. An update that moves a row between authentication scopes is treated like an update in the
  original scope and an update in the new scope. The user must have permission for both the update
  and the (pseudo) update for the change to be allowed.

  ## Filtering reads

  The `filter_read/2` function takes a `Permissions` and `Changes.Transaction` structs and filters
  the changes in the transaction according to the current permissions rules.

  The permissions verification process is the same as for verifying writes, except that the lookup
  in step 1 of that process always looks for permission to `:SELECT` on the relation in the
  change.

  ## Pending work

  1. `CHECK` clauses in GRANT statements are not validated at the moment

  2. Column subsetting in DDLX GRANT statements is ignored for the read path
  """
  use Electric.Satellite.Protobuf

  alias Electric.Replication.Changes
  alias Electric.Satellite.Permissions.{Grant, Read, Role, Scope, Transient}
  alias Electric.Satellite.{Auth, SatPerms}

  require Logger

  defstruct [
    :source,
    :roles,
    :scoped_roles,
    :auth,
    :scopes,
    :scope_resolver,
    transient_lut: Transient
  ]

  defmodule RoleGrant do
    # links a role to its corresponding grant
    @moduledoc false

    defstruct [:role, :grant]

    @type t() :: %__MODULE__{
            grant: Grant.t(),
            role: Role.t()
          }
  end

  defmodule MoveOut do
    # A message to the shapes system that the update encapsulated here has been moved out of the
    # user's permissions tree and should be deleted from their device.
    @moduledoc false

    defstruct [:change, :scope_path, :relation, :id]
  end

  defmodule ScopeMove do
    # A pseudo-change that we can use to verify that a user has permissions to move a row from
    # scope a to scope b. We create an instance of this struct with the updated row data, treat it
    # as though it were an update and then verify that the user has the required permission.
    # See `expand_change/2`, `required_permission/1` and `Scope.scope_id/3` for use.
    @moduledoc false

    defstruct [:relation, :record]
  end

  @type change() :: Changes.change()
  @type tx() :: Changes.Transaction.t()
  @type lsn() :: Electric.Postgres.Lsn.t()
  @type mode() :: :read | :write
  @type relation() :: Electric.Postgres.relation()
  @type privilege() :: :INSERT | :UPDATE | :DELETE | :SELECT
  @type table_permission() :: {relation(), privilege()}
  @type assigned_roles() :: %{unscoped: [RoleGrant.t()], scoped: [RoleGrant.t()]}
  @type role_lookup() :: %{table_permission() => assigned_roles()}
  @type scope_id() :: Electric.Postgres.pk()
  @type scope() :: {relation, scope_id()}
  @type scoped_change() :: {change(), scope()}
  @type move_out() :: %MoveOut{
          change: change(),
          scope_path: Scope.scope_path_information(),
          relation: relation(),
          id: scope_id()
        }

  @type empty() :: %__MODULE__{
          auth: Auth.t(),
          transient_lut: Transient.lut(),
          scope_resolver: Scope.t()
        }

  @type t() :: %__MODULE__{
          roles: role_lookup(),
          source: %{grants: [%SatPerms.Grant{}], roles: [%SatPerms.Role{}]} | nil,
          auth: Auth.t(),
          transient_lut: Transient.lut(),
          scope_resolver: Scope.t(),
          scopes: [relation()],
          scoped_roles: %{relation => [Role.t()]}
        }

  @doc """
  Configure a new empty permissions configuration with the given auth token, scope resolver and
  (optionally) a transient permissions lookup table name.

  Use `update/3` to add actual role and grant information.

  Arguments:

  - `auth` is the `#{Auth}` struct received from the connection auth
  - `scope_resolver` is an implementation of the `Permissions.Scope` behaviour in the
    form `{module, term}`
  - `transient_lut` (default: `#{Transient}`) is the name of the ETS table holding active
    transient permissions
  """
  @spec new(Auth.t(), Scope.t(), Transient.lut()) :: empty()
  def new(%Auth{} = auth, {_, _} = scope_resolver, transient_lut_name \\ Transient) do
    %__MODULE__{
      auth: auth,
      scope_resolver: scope_resolver,
      transient_lut: transient_lut_name
    }
  end

  @doc """
  Build a permissions struct that can be used to filter changes from the replication stream.

  Arguments:

  - `grants` should be a list of `%SatPerms.Grant{}` protobuf structs
  - `roles` should be a list of `%SatPerms.Role{}` protobuf structs

  """
  @spec update(empty() | t(), [%SatPerms.Grant{}], [%SatPerms.Role{}]) :: t()
  def update(%__MODULE__{} = perms, grants, roles) do
    assigned_roles = build_roles(roles, perms.auth)

    role_grants =
      assigned_roles
      |> Stream.map(&{&1, Role.matching_grants(&1, grants)})
      |> Stream.reject(fn {_role, grants} -> Enum.empty?(grants) end)
      |> Stream.map(&build_grants/1)
      |> Stream.flat_map(&invert_role_lookup/1)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(&classify_roles/1)

    scoped_roles = compile_scopes(assigned_roles)

    %{
      perms
      | source: %{grants: grants, roles: roles},
        roles: role_grants,
        scoped_roles: scoped_roles,
        scopes: Map.keys(scoped_roles)
    }
  end

  # For every `{table, privilege}` tuple we have a set of roles that the current user has.
  # If any of those roles are global, then it's equvilent to saying that the user can perform
  # `privilege` on `table` no matter what the scope. This function analyses the roles for a
  # given `{table, privilege}` and makes that test efficient by allowing for prioritising the
  # unscoped grant test.
  defp classify_roles({grant_perm, role_grants}) do
    {scoped, unscoped} =
      Enum.split_with(role_grants, &Role.has_scope?(&1.role))

    {grant_perm, %{scoped: scoped, unscoped: unscoped}}
  end

  # expand the grants into a list of `{{relation, privilege}, %RoleGrant{}}`
  # so that we can create a LUT of table and required privilege to role
  defp invert_role_lookup({role, grants}) do
    Stream.flat_map(grants, fn grant ->
      Enum.map(grant.privileges, &{{grant.table, &1}, %RoleGrant{grant: grant, role: role}})
    end)
  end

  defp build_grants({role, grants}) do
    {role, Enum.map(grants, &Grant.new/1)}
  end

  defp compile_scopes(roles) do
    roles
    |> Stream.filter(&Role.has_scope?/1)
    |> Stream.map(fn %{scope: {relation, _}} = role -> {relation, role} end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new()
  end

  defp build_roles(roles, auth) do
    roles
    |> Enum.map(&Role.new/1)
    |> add_authenticated(auth)
    |> add_anyone()
  end

  defp add_anyone(roles) do
    [%Role.Anyone{} | roles]
  end

  defp add_authenticated(roles, %Auth{user_id: nil}) do
    roles
  end

  defp add_authenticated(roles, %Auth{user_id: user_id}) do
    [%Role.Authenticated{user_id: user_id} | roles]
  end

  @doc """
  Filters the `changes` in a transaction coming out from postgres to the satellite clients.

  Removes any changes that the client doesn't have permissions to see and a list of
  `%Permissions.MoveOut{}` structs representing changes in the current tx that were made
  unreadable by the actions within that tx.

  E.g. if a transaction contains an update the moves a row out of its previously visible scope
  into a scope that the user doesn't have permissions to read, then this update will itself be
  filtered out by the new permissions scope it represents but included in the list of move-out
  messages.
  """
  @spec filter_read(t(), tx()) :: {tx(), [move_out()]}
  def filter_read(%__MODULE__{} = perms, %Changes.Transaction{} = tx) do
    Read.filter_read(perms, tx)
  end

  def validate_read(change, perms, scope_resolver, lsn) do
    if role_grants = Map.get(perms.roles, {change.relation, :SELECT}) do
      role_grant_for_change(role_grants, perms, scope_resolver, change, lsn, :read)
    end
  end

  @doc """
  Verify that all the writes in a transaction from satellite are allowed given the user's
  permissions.
  """
  @spec validate_write(t(), tx()) :: :ok | {:error, String.t()}
  def validate_write(%__MODULE__{} = perms, %Changes.Transaction{} = tx) do
    tx.changes
    |> Stream.flat_map(&expand_change(&1, perms))
    |> validate_all_writes(perms, tx.lsn)
  end

  defp expand_change(%Changes.UpdatedRecord{} = change, perms) do
    if modifies_scope_fk?(change, perms) do
      # expand an update that modifies a foreign key into the original update plus a
      # pseudo-update into the scope defined by the updated foreign key
      move = %ScopeMove{
        relation: change.relation,
        record: change.record
      }

      [change, move]
    else
      [change]
    end
  end

  defp expand_change(change, _perms) do
    [change]
  end

  defp modifies_scope_fk?(change, perms) do
    Enum.any?(perms.scopes, &Scope.modifies_fk?(perms.scope_resolver, &1, change))
  end

  defp validate_all_writes(changes, perms, lsn) do
    with {:ok, _tx_scope} <- validate_writes_with_scope(changes, perms, lsn) do
      :ok
    end
  end

  defp validate_writes_with_scope(changes, perms, lsn) do
    Enum.reduce_while(changes, {:ok, perms.scope_resolver}, fn change, {:ok, scope_resolver} ->
      case verify_write(change, perms, scope_resolver, lsn) do
        {:error, _} = error ->
          {:halt, error}

        %{role: role, grant: grant} = _role_grant ->
          Logger.debug(
            "role #{inspect(role)} grant #{inspect(grant)} gives permission for #{inspect(change)}"
          )

          scope_resolver = Scope.apply_change(scope_resolver, change)

          {:cont, {:ok, scope_resolver}}
      end
    end)
  end

  @spec verify_write(change(), t(), Scope.t(), lsn()) :: RoleGrant.t() | {:error, String.t()}
  defp verify_write(change, perms, scope_resolve, lsn) do
    action = required_permission(change)

    role_grant =
      perms.roles
      |> Map.get(action)
      |> role_grant_for_change(perms, scope_resolve, change, lsn, :write)

    role_grant || permission_error(action)
  end

  @spec role_grant_for_change(nil, t(), Scope.t(), change(), lsn(), mode()) :: nil
  defp role_grant_for_change(nil, _perms, _scope, _change, _lsn, _mode) do
    nil
  end

  @spec role_grant_for_change(assigned_roles(), t(), Scope.t(), change(), lsn(), mode()) ::
          RoleGrant.t() | nil
  defp role_grant_for_change(grants, perms, scope_resolv, change, lsn, mode) do
    %{unscoped: unscoped_role_grants, scoped: scoped_role_grants} = grants

    Stream.concat([
      unscoped_role_grants,
      scoped_role_grants(scoped_role_grants, perms, scope_resolv, change, lsn),
      transient_role_grants(scoped_role_grants, perms, scope_resolv, change, lsn)
    ])
    |> find_grant_allowing_change(change, mode)
  end

  defp scoped_role_grants(role_grants, _perms, scope_resolv, change, _lsn) do
    Stream.filter(role_grants, fn
      %{role: %{scope: {scope_table, scope_id}}} ->
        # filter out roles whose scope doesn't match
        #   - lookup their root id from the change
        #   - then reject roles that don't match the {table, pk_id}

        change_in_scope?(scope_resolv, scope_table, scope_id, change)
    end)
  end

  defp transient_role_grants(role_grants, perms, scope_resolv, change, lsn) do
    role_grants
    |> Transient.for_roles(lsn, perms.transient_lut)
    |> Stream.flat_map(fn {role_grant, %Transient{target_relation: relation, target_id: id} = tdp} ->
      if change_in_scope?(scope_resolv, relation, id, change) do
        Logger.debug(fn ->
          "Using transient permission #{inspect(tdp)} for #{inspect(change)}"
        end)

        [role_grant]
      else
        []
      end
    end)
  end

  @spec find_grant_allowing_change(Enum.t(), change(), :write) :: RoleGrant.t() | nil
  defp find_grant_allowing_change(role_grants, change, :write) do
    role_grants
    |> Enum.find(fn %{grant: grant} ->
      # ensure that change is compatible with grant conditions
      # note that we're allowing the change if *any* grant allows it
      change_matches_columns?(grant, change) && change_passes_check?(grant, change)
    end)
  end

  @spec find_grant_allowing_change([RoleGrant.t()], change(), :read) ::
          RoleGrant.t() | nil
  defp find_grant_allowing_change(role_grants, change, :read) do
    Enum.find(
      role_grants,
      fn %{grant: grant} -> change_passes_check?(grant, change) end
    )
  end

  defp change_matches_columns?(grant, %Changes.NewRecord{} = insert) do
    Grant.columns_valid?(grant, Map.keys(insert.record))
  end

  defp change_matches_columns?(grant, %Changes.UpdatedRecord{} = update) do
    Grant.columns_valid?(grant, update.changed_columns)
  end

  defp change_matches_columns?(_grant, _deleted_record) do
    true
  end

  defp change_passes_check?(%{check: nil}, _change) do
    true
  end

  defp change_passes_check?(_grant, _change) do
    # TODO: test change against check function
    true
  end

  defp change_in_scope?(scope_resolver, scope_relation, scope_id, change) do
    with {id, _path_information} <- Scope.scope_id(scope_resolver, scope_relation, change) do
      id && id == scope_id
    end
  end

  defp required_permission(%change{relation: relation}) do
    case change do
      Changes.NewRecord -> {relation, :INSERT}
      Changes.UpdatedRecord -> {relation, :UPDATE}
      Changes.DeletedRecord -> {relation, :DELETE}
      # We treat moving a record between permissions scope as requiring UPDATE permissions on both
      # the original and new permissions scopes.
      ScopeMove -> {relation, :UPDATE}
    end
  end

  defp permission_error({relation, privilege}) do
    action =
      case privilege do
        :INSERT -> "INSERT INTO "
        :DELETE -> "DELETE FROM "
        :UPDATE -> "UPDATE "
      end

    {:error,
     "user does not have permission to " <>
       action <> Electric.Utils.inspect_relation(relation)}
  end
end
