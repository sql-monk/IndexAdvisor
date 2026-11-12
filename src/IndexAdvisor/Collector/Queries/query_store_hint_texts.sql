-- Тексти запитів Query Store за весь період зберігання, що можуть містити табличні хінти індексів.
SELECT
	q.query_id AS queryId,
	qt.query_sql_text AS queryText
FROM sys.query_store_query AS q
INNER JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE UPPER(qt.query_sql_text) LIKE N'%INDEX%(%'
	OR UPPER(qt.query_sql_text) LIKE N'%INDEX%=%'
	OR UPPER(qt.query_sql_text) LIKE N'%FORCESEEK%'
ORDER BY q.query_id;
