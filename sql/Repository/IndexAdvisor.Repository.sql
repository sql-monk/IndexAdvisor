/*
	IndexAdvisor.Repository.sql — ідемпотентне створення схеми бази-репозиторію IndexAdvisor (CONTRACTS.md, розділ 8).
	Виконується в окремій базі-репозиторії (за замовчуванням IndexAdvisor), ніколи в цільових базах аналізу.
	Базу створює DBA заздалегідь (розміщення файлів — за стандартами середовища).

	Репозиторій зберігає лише результати аналізу: рекомендації, обґрунтування, T-SQL виконання й відкату, модель, токени, вартість
	і період роботи сервера. Сирі дані DMV і Query Store тут не зберігаються.

	Права лише через роль бази [db_index_advisor] (SELECT, INSERT, UPDATE, DELETE на схему Advisor); логін програми — член ролі.
	sqlcmd-змінна RepositoryLogin — логін, під яким програма пише в репозиторій (порожньо — членство не змінюється):
		sqlcmd -S REPO01 -d IndexAdvisor -E -b -i IndexAdvisor.Repository.sql -v RepositoryLogin="CONTOSO\index-advisor"
	Для SQLCMD-режиму SSMS додайте на початку рядок:  :setvar RepositoryLogin "CONTOSO\index-advisor"
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF DB_NAME() IN (N'master', N'model', N'msdb', N'tempdb', N'distribution')
	THROW 50001, N'Скрипт виконується в базі-репозиторії IndexAdvisor (sqlcmd -d IndexAdvisor), а не в системній базі.', 1;
GO

IF SCHEMA_ID(N'Advisor') IS NULL
	EXEC (N'CREATE SCHEMA [Advisor] AUTHORIZATION [dbo];');
GO

IF OBJECT_ID(N'Advisor.AnalysisRun', N'U') IS NULL
BEGIN
	CREATE TABLE Advisor.AnalysisRun
	(
		RunId UNIQUEIDENTIFIER NOT NULL,
		Module VARCHAR(20) NOT NULL,
		RequestedServer NVARCHAR(256) NOT NULL,
		StartedAtUtc DATETIME2(3) NOT NULL,
		FinishedAtUtc DATETIME2(3) NULL,
		StartedBy NVARCHAR(256) NOT NULL,
		HostName NVARCHAR(256) NOT NULL,
		ToolVersion VARCHAR(32) NOT NULL,
		ParametersJson NVARCHAR(MAX) NOT NULL,
		FromArchive NVARCHAR(1024) NULL,
		ArchivePath NVARCHAR(1024) NULL,
		NamesMasked BIT NOT NULL,
		UnsafeFlags NVARCHAR(400) NULL,
		DatasetsJson NVARCHAR(MAX) NOT NULL,
		Provider NVARCHAR(100) NULL,
		Model NVARCHAR(200) NULL,
		InputTokens BIGINT NOT NULL,
		OutputTokens BIGINT NOT NULL,
		CostUsd DECIMAL(19, 6) NOT NULL,
		Status VARCHAR(20) NOT NULL,
		ExitCode INT NOT NULL,
		WarningsJson NVARCHAR(MAX) NULL,
		CONSTRAINT CI_RunId_UQ PRIMARY KEY CLUSTERED (RunId)
	);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Advisor.AnalysisRun') AND name = N'IX_StartedAtUtc')
	CREATE NONCLUSTERED INDEX IX_StartedAtUtc ON Advisor.AnalysisRun (StartedAtUtc);
GO

IF OBJECT_ID(N'Advisor.RunDataPeriod', N'U') IS NULL
BEGIN
	CREATE TABLE Advisor.RunDataPeriod
	(
		RunDataPeriodId BIGINT IDENTITY(1, 1) NOT NULL,
		RunId UNIQUEIDENTIFIER NOT NULL,
		ServerName NVARCHAR(256) NOT NULL,
		DatabaseName NVARCHAR(128) NULL,
		SqlServerStartTimeUtc DATETIME2(3) NOT NULL,
		LastFailoverUtc DATETIME2(3) NULL,
		StatsFromUtc DATETIME2(3) NOT NULL,
		StatsToUtc DATETIME2(3) NOT NULL,
		UptimeDays DECIMAL(9, 2) NOT NULL,
		QueryStoreFromUtc DATETIME2(3) NULL,
		QueryStoreToUtc DATETIME2(3) NULL,
		QueryStoreDays DECIMAL(9, 2) NULL,
		MinRequiredDays INT NOT NULL,
		IsSufficient BIT NOT NULL,
		CONSTRAINT CI_RunDataPeriodId_UQ PRIMARY KEY CLUSTERED (RunDataPeriodId),
		CONSTRAINT FK_RunDataPeriod_AnalysisRun FOREIGN KEY (RunId) REFERENCES Advisor.AnalysisRun (RunId) ON DELETE CASCADE
	);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Advisor.RunDataPeriod') AND name = N'IX_RunId')
	CREATE NONCLUSTERED INDEX IX_RunId ON Advisor.RunDataPeriod (RunId);
GO

IF OBJECT_ID(N'Advisor.LlmCall', N'U') IS NULL
BEGIN
	CREATE TABLE Advisor.LlmCall
	(
		LlmCallId UNIQUEIDENTIFIER NOT NULL,
		RunId UNIQUEIDENTIFIER NOT NULL,
		Purpose VARCHAR(20) NOT NULL,
		Provider NVARCHAR(100) NOT NULL,
		Model NVARCHAR(200) NOT NULL,
		PromptTemplateId VARCHAR(100) NULL,
		PromptTemplateVersion INT NULL,
		InputTokens INT NOT NULL,
		OutputTokens INT NOT NULL,
		CostUsd DECIMAL(19, 6) NOT NULL,
		DurationMs INT NOT NULL,
		Success BIT NOT NULL,
		CreatedAtUtc DATETIME2(3) NOT NULL,
		CONSTRAINT CI_LlmCallId_UQ PRIMARY KEY CLUSTERED (LlmCallId),
		CONSTRAINT FK_LlmCall_AnalysisRun FOREIGN KEY (RunId) REFERENCES Advisor.AnalysisRun (RunId) ON DELETE CASCADE
	);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Advisor.LlmCall') AND name = N'IX_RunId')
	CREATE NONCLUSTERED INDEX IX_RunId ON Advisor.LlmCall (RunId);
GO

IF OBJECT_ID(N'Advisor.ToolRequest', N'U') IS NULL
BEGIN
	CREATE TABLE Advisor.ToolRequest
	(
		ToolRequestId UNIQUEIDENTIFIER NOT NULL,
		RunId UNIQUEIDENTIFIER NOT NULL,
		LlmCallId UNIQUEIDENTIFIER NULL,
		ToolName NVARCHAR(128) NOT NULL,
		ServerName NVARCHAR(256) NULL,
		DatabaseName NVARCHAR(128) NULL,
		ArgumentsJson NVARCHAR(MAX) NOT NULL,
		Decision VARCHAR(20) NOT NULL,
		[RowCount] INT NULL,
		Truncated BIT NULL,
		Success BIT NULL,
		ExecutedAtUtc DATETIME2(3) NULL,
		CONSTRAINT CI_ToolRequestId_UQ PRIMARY KEY CLUSTERED (ToolRequestId),
		CONSTRAINT FK_ToolRequest_AnalysisRun FOREIGN KEY (RunId) REFERENCES Advisor.AnalysisRun (RunId) ON DELETE CASCADE
	);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Advisor.ToolRequest') AND name = N'IX_RunId')
	CREATE NONCLUSTERED INDEX IX_RunId ON Advisor.ToolRequest (RunId);
GO

IF OBJECT_ID(N'Advisor.Recommendation', N'U') IS NULL
BEGIN
	CREATE TABLE Advisor.Recommendation
	(
		RecommendationId UNIQUEIDENTIFIER NOT NULL,
		RunId UNIQUEIDENTIFIER NOT NULL,
		Module VARCHAR(20) NOT NULL,
		Action VARCHAR(30) NOT NULL,
		Source VARCHAR(10) NOT NULL,
		ObjectKey NVARCHAR(850) NOT NULL,
		ServerName NVARCHAR(256) NOT NULL,
		DatabaseName NVARCHAR(128) NOT NULL,
		SchemaName NVARCHAR(128) NOT NULL,
		TableName NVARCHAR(128) NOT NULL,
		IndexName NVARCHAR(128) NULL,
		Title NVARCHAR(400) NOT NULL,
		Rationale NVARCHAR(MAX) NOT NULL,
		RiskLevel VARCHAR(10) NOT NULL,
		RiskDescription NVARCHAR(MAX) NOT NULL,
		ExecuteScript NVARCHAR(MAX) NOT NULL,
		RollbackScript NVARCHAR(MAX) NOT NULL,
		ValidationStatus VARCHAR(20) NOT NULL,
		ValidationJson NVARCHAR(MAX) NOT NULL,
		DropEligibilityJson NVARCHAR(MAX) NULL,
		IsDropEligible BIT NULL,
		RulesProfile VARCHAR(10) NULL,
		CrossCheckJson NVARCHAR(MAX) NULL,
		Provider NVARCHAR(100) NULL,
		Model NVARCHAR(200) NULL,
		PromptTemplateId VARCHAR(100) NULL,
		PromptTemplateVersion INT NULL,
		PeriodFromUtc DATETIME2(3) NULL,
		PeriodToUtc DATETIME2(3) NULL,
		UptimeDays DECIMAL(9, 2) NULL,
		WarningsJson NVARCHAR(MAX) NULL,
		RecommendationJson NVARCHAR(MAX) NOT NULL,
		CreatedAtUtc DATETIME2(3) NOT NULL,
		CONSTRAINT CI_RecommendationId_UQ PRIMARY KEY CLUSTERED (RecommendationId),
		CONSTRAINT FK_Recommendation_AnalysisRun FOREIGN KEY (RunId) REFERENCES Advisor.AnalysisRun (RunId) ON DELETE CASCADE
	);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Advisor.Recommendation') AND name = N'IX_ObjectKey_CreatedAtUtc')
	CREATE NONCLUSTERED INDEX IX_ObjectKey_CreatedAtUtc ON Advisor.Recommendation (ObjectKey, CreatedAtUtc);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Advisor.Recommendation') AND name = N'IX_RunId')
	CREATE NONCLUSTERED INDEX IX_RunId ON Advisor.Recommendation (RunId);
GO

IF OBJECT_ID(N'Advisor.ObjectVerdict', N'U') IS NULL
BEGIN
	CREATE TABLE Advisor.ObjectVerdict
	(
		RunId UNIQUEIDENTIFIER NOT NULL,
		ObjectKey NVARCHAR(850) NOT NULL,
		Module VARCHAR(20) NOT NULL,
		AnalyzedAtUtc DATETIME2(3) NOT NULL,
		Verdict VARCHAR(20) NOT NULL,
		CountsTowardSeries BIT NOT NULL,
		PeriodDays DECIMAL(9, 2) NOT NULL,
		RulesProfile VARCHAR(10) NULL,
		CONSTRAINT CI_RunId_ObjectKey_UQ PRIMARY KEY CLUSTERED (RunId, ObjectKey),
		CONSTRAINT FK_ObjectVerdict_AnalysisRun FOREIGN KEY (RunId) REFERENCES Advisor.AnalysisRun (RunId) ON DELETE CASCADE
	);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Advisor.ObjectVerdict') AND name = N'IX_ObjectKey_AnalyzedAtUtc')
	CREATE NONCLUSTERED INDEX IX_ObjectKey_AnalyzedAtUtc ON Advisor.ObjectVerdict (ObjectKey, AnalyzedAtUtc);
GO

-- Роль бази для програми: лише дані схеми Advisor.
IF USER_ID('db_index_advisor') IS NULL CREATE ROLE [db_index_advisor];
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::[Advisor] TO [db_index_advisor];
GO

-- Користувач і членство логіна програми в ролі (якщо задано RepositoryLogin).
DECLARE @repositoryLogin NVARCHAR(128) = TRIM(N'$(RepositoryLogin)');
DECLARE @sql NVARCHAR(MAX);
IF @repositoryLogin <> N''
BEGIN
	IF SUSER_ID(@repositoryLogin) IS NULL
	BEGIN
		RAISERROR(N'Логін %s не існує на сервері репозиторію: створіть його й повторіть скрипт.', 16, 1, @repositoryLogin);
		RETURN;
	END;
	IF USER_ID(@repositoryLogin) IS NULL
	BEGIN
		SET @sql = CONCAT(N'CREATE USER ', QUOTENAME(@repositoryLogin), N' FOR LOGIN ', QUOTENAME(@repositoryLogin), N';');
		EXEC sys.sp_executesql @sql;
	END;
	IF NOT EXISTS (
		SELECT 1
		FROM sys.database_role_members AS rm
		WHERE rm.role_principal_id = USER_ID(N'db_index_advisor')
			AND rm.member_principal_id = USER_ID(@repositoryLogin)
	)
	BEGIN
		SET @sql = CONCAT(N'ALTER ROLE [db_index_advisor] ADD MEMBER ', QUOTENAME(@repositoryLogin), N';');
		EXEC sys.sp_executesql @sql;
	END;
END;
GO
