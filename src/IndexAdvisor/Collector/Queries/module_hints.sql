-- Модулі (процедури, функції, представлення, тригери), текст яких може містити табличні хінти індексів.
SELECT
	m.object_id AS objectId,
	OBJECT_SCHEMA_NAME(m.object_id) AS schemaName,
	OBJECT_NAME(m.object_id) AS moduleName,
	m.definition AS moduleDefinition
FROM sys.sql_modules AS m
WHERE UPPER(m.definition) LIKE N'%INDEX%(%'
	OR UPPER(m.definition) LIKE N'%INDEX%=%'
	OR UPPER(m.definition) LIKE N'%FORCESEEK%'
ORDER BY m.object_id;
