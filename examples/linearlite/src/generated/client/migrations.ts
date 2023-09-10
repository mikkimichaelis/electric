export default [
  {
    "statements": [
      "CREATE TABLE \"issue\" (\n  \"id\" TEXT NOT NULL,\n  \"title\" TEXT NOT NULL,\n  \"description\" TEXT NOT NULL,\n  \"priority\" TEXT NOT NULL,\n  \"status\" TEXT NOT NULL,\n  \"modified\" TEXT NOT NULL,\n  \"created\" TEXT NOT NULL,\n  \"kanbanorder\" TEXT NOT NULL,\n  \"username\" TEXT NOT NULL,\n  CONSTRAINT \"issue_pkey\" PRIMARY KEY (\"id\")\n) WITHOUT ROWID;\n",
      "CREATE TABLE \"comment\" (\n  \"id\" TEXT NOT NULL,\n  \"body\" TEXT NOT NULL,\n  \"username\" TEXT NOT NULL,\n  \"issue_id\" TEXT NOT NULL,\n  \"created_at\" TEXT NOT NULL,\n  CONSTRAINT \"comment_issue_id_fkey\" FOREIGN KEY (\"issue_id\") REFERENCES \"issue\" (\"id\"),\n  CONSTRAINT \"comment_pkey\" PRIMARY KEY (\"id\")\n) WITHOUT ROWID;\n",
      "\n    -- Toggles for turning the triggers on and off\n    INSERT OR IGNORE INTO _electric_trigger_settings(tablename,flag) VALUES ('main.issue', 1);\n    ",
      "\n    /* Triggers for table issue */\n  \n    -- ensures primary key is immutable\n    DROP TRIGGER IF EXISTS update_ensure_main_issue_primarykey;\n    ",
      "\n    CREATE TRIGGER update_ensure_main_issue_primarykey\n      BEFORE UPDATE ON main.issue\n    BEGIN\n      SELECT\n        CASE\n          WHEN old.id != new.id THEN\n\t\tRAISE (ABORT, 'cannot change the value of column id as it belongs to the primary key')\n        END;\n    END;\n    ",
      "\n    -- Triggers that add INSERT, UPDATE, DELETE operation to the _opslog table\n    DROP TRIGGER IF EXISTS insert_main_issue_into_oplog;\n    ",
      "\n    CREATE TRIGGER insert_main_issue_into_oplog\n       AFTER INSERT ON main.issue\n       WHEN 1 == (SELECT flag from _electric_trigger_settings WHERE tablename == 'main.issue')\n    BEGIN\n      INSERT INTO _electric_oplog (namespace, tablename, optype, primaryKey, newRow, oldRow, timestamp)\n      VALUES ('main', 'issue', 'INSERT', json_object('id', new.id), json_object('created', new.created, 'description', new.description, 'id', new.id, 'kanbanorder', new.kanbanorder, 'modified', new.modified, 'priority', new.priority, 'status', new.status, 'title', new.title, 'username', new.username), NULL, NULL);\n    END;\n    ",
      "\n    DROP TRIGGER IF EXISTS update_main_issue_into_oplog;\n    ",
      "\n    CREATE TRIGGER update_main_issue_into_oplog\n       AFTER UPDATE ON main.issue\n       WHEN 1 == (SELECT flag from _electric_trigger_settings WHERE tablename == 'main.issue')\n    BEGIN\n      INSERT INTO _electric_oplog (namespace, tablename, optype, primaryKey, newRow, oldRow, timestamp)\n      VALUES ('main', 'issue', 'UPDATE', json_object('id', new.id), json_object('created', new.created, 'description', new.description, 'id', new.id, 'kanbanorder', new.kanbanorder, 'modified', new.modified, 'priority', new.priority, 'status', new.status, 'title', new.title, 'username', new.username), json_object('created', old.created, 'description', old.description, 'id', old.id, 'kanbanorder', old.kanbanorder, 'modified', old.modified, 'priority', old.priority, 'status', old.status, 'title', old.title, 'username', old.username), NULL);\n    END;\n    ",
      "\n    DROP TRIGGER IF EXISTS delete_main_issue_into_oplog;\n    ",
      "\n    CREATE TRIGGER delete_main_issue_into_oplog\n       AFTER DELETE ON main.issue\n       WHEN 1 == (SELECT flag from _electric_trigger_settings WHERE tablename == 'main.issue')\n    BEGIN\n      INSERT INTO _electric_oplog (namespace, tablename, optype, primaryKey, newRow, oldRow, timestamp)\n      VALUES ('main', 'issue', 'DELETE', json_object('id', old.id), NULL, json_object('created', old.created, 'description', old.description, 'id', old.id, 'kanbanorder', old.kanbanorder, 'modified', old.modified, 'priority', old.priority, 'status', old.status, 'title', old.title, 'username', old.username), NULL);\n    END;\n    ",
      "\n    -- Toggles for turning the triggers on and off\n    INSERT OR IGNORE INTO _electric_trigger_settings(tablename,flag) VALUES ('main.comment', 1);\n    ",
      "\n    /* Triggers for table comment */\n  \n    -- ensures primary key is immutable\n    DROP TRIGGER IF EXISTS update_ensure_main_comment_primarykey;\n    ",
      "\n    CREATE TRIGGER update_ensure_main_comment_primarykey\n      BEFORE UPDATE ON main.comment\n    BEGIN\n      SELECT\n        CASE\n          WHEN old.id != new.id THEN\n\t\tRAISE (ABORT, 'cannot change the value of column id as it belongs to the primary key')\n        END;\n    END;\n    ",
      "\n    -- Triggers that add INSERT, UPDATE, DELETE operation to the _opslog table\n    DROP TRIGGER IF EXISTS insert_main_comment_into_oplog;\n    ",
      "\n    CREATE TRIGGER insert_main_comment_into_oplog\n       AFTER INSERT ON main.comment\n       WHEN 1 == (SELECT flag from _electric_trigger_settings WHERE tablename == 'main.comment')\n    BEGIN\n      INSERT INTO _electric_oplog (namespace, tablename, optype, primaryKey, newRow, oldRow, timestamp)\n      VALUES ('main', 'comment', 'INSERT', json_object('id', new.id), json_object('body', new.body, 'created_at', new.created_at, 'id', new.id, 'issue_id', new.issue_id, 'username', new.username), NULL, NULL);\n    END;\n    ",
      "\n    DROP TRIGGER IF EXISTS update_main_comment_into_oplog;\n    ",
      "\n    CREATE TRIGGER update_main_comment_into_oplog\n       AFTER UPDATE ON main.comment\n       WHEN 1 == (SELECT flag from _electric_trigger_settings WHERE tablename == 'main.comment')\n    BEGIN\n      INSERT INTO _electric_oplog (namespace, tablename, optype, primaryKey, newRow, oldRow, timestamp)\n      VALUES ('main', 'comment', 'UPDATE', json_object('id', new.id), json_object('body', new.body, 'created_at', new.created_at, 'id', new.id, 'issue_id', new.issue_id, 'username', new.username), json_object('body', old.body, 'created_at', old.created_at, 'id', old.id, 'issue_id', old.issue_id, 'username', old.username), NULL);\n    END;\n    ",
      "\n    DROP TRIGGER IF EXISTS delete_main_comment_into_oplog;\n    ",
      "\n    CREATE TRIGGER delete_main_comment_into_oplog\n       AFTER DELETE ON main.comment\n       WHEN 1 == (SELECT flag from _electric_trigger_settings WHERE tablename == 'main.comment')\n    BEGIN\n      INSERT INTO _electric_oplog (namespace, tablename, optype, primaryKey, newRow, oldRow, timestamp)\n      VALUES ('main', 'comment', 'DELETE', json_object('id', old.id), NULL, json_object('body', old.body, 'created_at', old.created_at, 'id', old.id, 'issue_id', old.issue_id, 'username', old.username), NULL);\n    END;\n    ",
      "-- Triggers for foreign key compensations\n      DROP TRIGGER IF EXISTS compensation_insert_main_comment_issue_id_into_oplog;",
      "\n      CREATE TRIGGER compensation_insert_main_comment_issue_id_into_oplog\n        AFTER INSERT ON main.comment\n        WHEN 1 == (SELECT flag from _electric_trigger_settings WHERE tablename == 'main.issue') AND\n             1 == (SELECT value from _electric_meta WHERE key == 'compensations')\n      BEGIN\n        INSERT INTO _electric_oplog (namespace, tablename, optype, primaryKey, newRow, oldRow, timestamp)\n        SELECT 'main', 'issue', 'UPDATE', json_object('id', id), json_object('id', id), NULL, NULL\n        FROM main.issue WHERE id = new.issue_id;\n      END;\n      ",
      "DROP TRIGGER IF EXISTS compensation_update_main_comment_issue_id_into_oplog;",
      "\n      CREATE TRIGGER compensation_update_main_comment_issue_id_into_oplog\n         AFTER UPDATE ON main.comment\n         WHEN 1 == (SELECT flag from _electric_trigger_settings WHERE tablename == 'main.issue') AND\n              1 == (SELECT value from _electric_meta WHERE key == 'compensations')\n      BEGIN\n        INSERT INTO _electric_oplog (namespace, tablename, optype, primaryKey, newRow, oldRow, timestamp)\n        SELECT 'main', 'issue', 'UPDATE', json_object('id', id), json_object('id', id), NULL, NULL\n        FROM main.issue WHERE id = new.issue_id;\n      END;\n      "
    ],
    "version": "20230910182812_238"
  }
]