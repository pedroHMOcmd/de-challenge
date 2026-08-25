/*
  Representative Azure SQL MI warehouse objects.
  In a Microsoft.Build.Sql project these objects would be split one per file.
*/

CREATE SCHEMA ingestion;
GO
CREATE SCHEMA transformation;
GO
CREATE SCHEMA reporting;
GO

CREATE TABLE ingestion.PipelineRun
(
    RunId             uniqueidentifier NOT NULL,
    StartedAtUtc      datetime2(3)     NOT NULL,
    ExtractUpperUtc   datetime2(3)     NOT NULL,
    CompletedAtUtc    datetime2(3)     NULL,
    Status             varchar(12)      NOT NULL,
    RowsPublished      bigint           NULL,
    RowsRejected       bigint           NULL,
    CONSTRAINT PK_PipelineRun PRIMARY KEY (RunId),
    CONSTRAINT CK_PipelineRun_Status
        CHECK (Status IN ('RUNNING', 'SUCCEEDED', 'FAILED'))
);
GO

CREATE TABLE ingestion.Watermark
(
    SourceObject       varchar(128)  NOT NULL,
    LastSuccessfulUtc  datetime2(3)  NOT NULL,
    LastRunId          uniqueidentifier NULL,
    CONSTRAINT PK_Watermark PRIMARY KEY (SourceObject),
    CONSTRAINT FK_Watermark_Run FOREIGN KEY (LastRunId)
        REFERENCES ingestion.PipelineRun (RunId)
);
GO

CREATE TABLE ingestion.ErrorLog
(
    ErrorId          bigint IDENTITY(1,1) NOT NULL,
    RunId            uniqueidentifier     NOT NULL,
    Severity         varchar(8)           NOT NULL,
    SourceObject     varchar(128)         NOT NULL,
    SourceKey        varchar(200)         NULL,
    ErrorCode        varchar(50)          NOT NULL,
    ErrorDetail      nvarchar(1000)       NULL,
    SourcePayload    nvarchar(max)        NULL,
    LoggedAtUtc      datetime2(3)         NOT NULL
        CONSTRAINT DF_ErrorLog_LoggedAt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_ErrorLog PRIMARY KEY (ErrorId),
    CONSTRAINT FK_ErrorLog_Run FOREIGN KEY (RunId)
        REFERENCES ingestion.PipelineRun (RunId),
    CONSTRAINT CK_ErrorLog_Severity CHECK (Severity IN ('WARNING', 'ERROR')),
    CONSTRAINT CK_ErrorLog_Payload CHECK (SourcePayload IS NULL OR ISJSON(SourcePayload) = 1)
);
GO

CREATE TABLE ingestion.FxRate
(
    RateDate          date            NOT NULL,
    CurrencyFrom      char(3)         NOT NULL,
    CurrencyTo        char(3)         NOT NULL,
    ConversionRate    decimal(19,10)  NOT NULL,
    Provider          varchar(100)    NOT NULL,
    RunId             uniqueidentifier NOT NULL,
    LoadedAtUtc       datetime2(3)    NOT NULL
        CONSTRAINT DF_FxRate_LoadedAt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_FxRate PRIMARY KEY (RateDate, CurrencyFrom, CurrencyTo),
    CONSTRAINT FK_FxRate_Run FOREIGN KEY (RunId)
        REFERENCES ingestion.PipelineRun (RunId),
    CONSTRAINT CK_FxRate_Positive CHECK (ConversionRate > 0),
    CONSTRAINT CK_FxRate_Upper CHECK
        (CurrencyFrom = UPPER(CurrencyFrom) AND CurrencyTo = UPPER(CurrencyTo))
);
GO

/* ADF replaces these two tables only after validating complete snapshots. */
CREATE TABLE ingestion.CustomerSnapshot
(
    CustomerId          int            NOT NULL,
    CustomerName        nvarchar(100)  NOT NULL,
    Email               nvarchar(150)  NOT NULL,
    RegistrationDateUtc datetime2(0)   NOT NULL,
    Country             nvarchar(50)   NOT NULL,
    RunId               uniqueidentifier NOT NULL,
    CONSTRAINT PK_CustomerSnapshot PRIMARY KEY (CustomerId)
);
GO

CREATE TABLE ingestion.OrderItemSnapshot
(
    OrderItemId       int             NOT NULL,
    OrderId           int             NOT NULL,
    ProductId         int             NOT NULL,
    Quantity          int             NOT NULL,
    UnitPrice         decimal(10,2)   NOT NULL,
    Currency          nvarchar(3)     NOT NULL,
    RunId             uniqueidentifier NOT NULL,
    CONSTRAINT PK_OrderItemSnapshot PRIMARY KEY (OrderItemId),
    CONSTRAINT UQ_OrderItemSnapshot_OrderLine UNIQUE (OrderId, OrderItemId)
);
GO

/* Latest source state maintained from the temporal order delta. */
CREATE TABLE ingestion.OrderCurrent
(
    OrderId           int             NOT NULL,
    CustomerId        int             NOT NULL,
    OrderDateUtc      datetime2(0)    NOT NULL,
    HeaderTotal       decimal(10,2)   NOT NULL,
    HeaderCurrency    nvarchar(3)     NOT NULL,
    OrderStatus       nvarchar(20)    NOT NULL,
    SourceValidFrom   datetime2(3)    NOT NULL,
    IsDeleted         bit             NOT NULL,
    RunId             uniqueidentifier NOT NULL,
    CONSTRAINT PK_OrderCurrent PRIMARY KEY (OrderId)
);
GO

/* Every version from dbo.product_descriptions, not only the current row. */
CREATE TABLE ingestion.ProductVersion
(
    ProductId         int             NOT NULL,
    ProductName       nvarchar(200)   NOT NULL,
    Category          nvarchar(100)   NOT NULL,
    ProductDescription nvarchar(max)  NULL,
    BasePrice         decimal(10,2)   NOT NULL,
    Currency          nvarchar(3)     NOT NULL,
    SourceValidFrom   datetime2(3)    NOT NULL,
    SourceValidTo     datetime2(3)    NOT NULL,
    RunId             uniqueidentifier NOT NULL,
    CONSTRAINT PK_ProductVersion PRIMARY KEY (ProductId, SourceValidFrom),
    CONSTRAINT CK_ProductVersion_Range CHECK (SourceValidFrom < SourceValidTo)
);
GO

CREATE TABLE reporting.DimDate
(
    DateKey          int          NOT NULL,
    FullDate         date         NOT NULL,
    DayOfWeekNumber  tinyint      NOT NULL,
    DayOfWeekName    varchar(9)   NOT NULL,
    DayOfMonth       tinyint      NOT NULL,
    MonthNumber      tinyint      NOT NULL,
    MonthName        varchar(9)   NOT NULL,
    QuarterNumber    tinyint      NOT NULL,
    CalendarYear     smallint     NOT NULL,
    CONSTRAINT PK_DimDate PRIMARY KEY (DateKey),
    CONSTRAINT UQ_DimDate_FullDate UNIQUE (FullDate),
    CONSTRAINT CK_DimDate_Key CHECK
        (DateKey = -1 OR DateKey = CONVERT(int, CONVERT(char(8), FullDate, 112)))
);
GO

CREATE TABLE reporting.DimTime
(
    TimeKey          int          NOT NULL,
    TimeValue        time(0)      NOT NULL,
    Hour24           tinyint      NOT NULL,
    MinuteNumber     tinyint      NOT NULL,
    TimeOfDayBucket  varchar(12)  NOT NULL,
    CONSTRAINT PK_DimTime PRIMARY KEY (TimeKey),
    CONSTRAINT UQ_DimTime_Value UNIQUE (TimeValue),
    CONSTRAINT CK_DimTime_Hour CHECK (Hour24 BETWEEN 0 AND 23),
    CONSTRAINT CK_DimTime_Minute CHECK (MinuteNumber BETWEEN 0 AND 59),
    CONSTRAINT CK_DimTime_Key CHECK
        (TimeKey = -1 OR TimeKey = Hour24 * 100 + MinuteNumber),
    CONSTRAINT CK_DimTime_Bucket CHECK
        (TimeKey = -1 OR TimeOfDayBucket IN ('Night', 'Morning', 'Afternoon', 'Evening'))
);
GO

CREATE TABLE reporting.DimCustomer
(
    CustomerKey       int IDENTITY(1,1) NOT NULL,
    CustomerId        int            NOT NULL,
    CustomerName      nvarchar(100)  NOT NULL,
    Email             nvarchar(150)  NULL,
    Country           nvarchar(50)   NULL,
    RegistrationDate  date           NULL,
    CONSTRAINT PK_DimCustomer PRIMARY KEY (CustomerKey),
    CONSTRAINT UQ_DimCustomer_Id UNIQUE (CustomerId)
);
GO

CREATE TABLE reporting.DimProduct
(
    ProductKey        int IDENTITY(1,1) NOT NULL,
    ProductId         int             NOT NULL,
    ProductName       nvarchar(200)   NOT NULL,
    Category          nvarchar(100)   NOT NULL,
    ProductDescription nvarchar(max)  NULL,
    BasePrice         decimal(10,2)   NOT NULL,
    Currency          char(3)         NOT NULL,
    ValidFromUtc      datetime2(3)    NOT NULL,
    ValidToUtc        datetime2(3)    NOT NULL,
    IsCurrent         bit             NOT NULL,
    CONSTRAINT PK_DimProduct PRIMARY KEY (ProductKey),
    CONSTRAINT UQ_DimProduct_Version UNIQUE (ProductId, ValidFromUtc),
    CONSTRAINT CK_DimProduct_Price CHECK (ProductId = -1 OR BasePrice > 0),
    CONSTRAINT CK_DimProduct_Range CHECK (ValidFromUtc < ValidToUtc)
);
GO

CREATE UNIQUE INDEX UX_DimProduct_Current
    ON reporting.DimProduct (ProductId)
    WHERE IsCurrent = 1;
GO

CREATE TABLE reporting.FactSales
(
    SalesFactId       bigint IDENTITY(1,1) NOT NULL,
    OrderDateKey      int             NOT NULL,
    OrderTimeKey      int             NOT NULL,
    ProductKey        int             NOT NULL,
    CustomerKey       int             NOT NULL,
    OrderId           int             NOT NULL,
    OrderItemId       int             NOT NULL,
    Quantity          int             NOT NULL,
    UnitPriceOriginal decimal(19,4)   NOT NULL,
    OriginalCurrency  char(3)         NOT NULL,
    FxRateToUsd       decimal(19,10)  NOT NULL,
    UnitPriceUsd      decimal(19,4)   NOT NULL,
    TotalAmountUsd    decimal(19,4)   NOT NULL,
    LoadRunId         uniqueidentifier NOT NULL,
    LoadedAtUtc       datetime2(3)    NOT NULL
        CONSTRAINT DF_FactSales_LoadedAt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_FactSales PRIMARY KEY (SalesFactId),
    CONSTRAINT UQ_FactSales_OrderLine UNIQUE (OrderId, OrderItemId),
    CONSTRAINT FK_FactSales_Date FOREIGN KEY (OrderDateKey)
        REFERENCES reporting.DimDate (DateKey),
    CONSTRAINT FK_FactSales_Time FOREIGN KEY (OrderTimeKey)
        REFERENCES reporting.DimTime (TimeKey),
    CONSTRAINT FK_FactSales_Product FOREIGN KEY (ProductKey)
        REFERENCES reporting.DimProduct (ProductKey),
    CONSTRAINT FK_FactSales_Customer FOREIGN KEY (CustomerKey)
        REFERENCES reporting.DimCustomer (CustomerKey),
    CONSTRAINT FK_FactSales_Run FOREIGN KEY (LoadRunId)
        REFERENCES ingestion.PipelineRun (RunId),
    CONSTRAINT CK_FactSales_Quantity CHECK (Quantity > 0),
    CONSTRAINT CK_FactSales_Prices CHECK
        (UnitPriceOriginal > 0 AND FxRateToUsd > 0 AND UnitPriceUsd > 0 AND TotalAmountUsd > 0)
);
GO

CREATE INDEX IX_FactSales_DateProduct
    ON reporting.FactSales (OrderDateKey, ProductKey)
    INCLUDE (Quantity, TotalAmountUsd);
GO

/*
  Post-deploy also seeds -1 unknown members and the reporting calendar. For the
  initial product load, ADF maps each product's earliest SourceValidFrom to
  1900-01-01. The sample's business orders predate the time its setup SQL runs.

  SET IDENTITY_INSERT reporting.DimCustomer ON;
  INSERT reporting.DimCustomer
      (CustomerKey, CustomerId, CustomerName, Email, Country, RegistrationDate)
  VALUES (-1, -1, 'Unknown', NULL, NULL, NULL);
  SET IDENTITY_INSERT reporting.DimCustomer OFF;

  SET IDENTITY_INSERT reporting.DimProduct ON;
  INSERT reporting.DimProduct
      (ProductKey, ProductId, ProductName, Category, ProductDescription,
       BasePrice, Currency, ValidFromUtc, ValidToUtc, IsCurrent)
  VALUES
      (-1, -1, 'Unknown', 'Unknown', NULL, 0, 'USD',
       '1900-01-01', '9999-12-31 23:59:59.999', 1);
  SET IDENTITY_INSERT reporting.DimProduct OFF;

  INSERT reporting.DimDate
      (DateKey, FullDate, DayOfWeekNumber, DayOfWeekName, DayOfMonth,
       MonthNumber, MonthName, QuarterNumber, CalendarYear)
  VALUES (-1, '0001-01-01', 0, 'Unknown', 0, 0, 'Unknown', 0, 0);

  INSERT reporting.DimTime
      (TimeKey, TimeValue, Hour24, MinuteNumber, TimeOfDayBucket)
  VALUES (-1, '23:59:59', 0, 0, 'Unknown');
*/

/*
  ADF source-query pattern for a temporal table.
  @high is obtained from SELECT SYSUTCDATETIME() on the source once per run.
  Both boundaries are half-open, so consecutive runs do not overlap.

  SELECT o.*, CASE WHEN current_row.id IS NULL THEN 1 ELSE 0 END AS is_deleted
  FROM dbo.orders FOR SYSTEM_TIME ALL AS o
  LEFT JOIN dbo.orders AS current_row ON current_row.id = o.id
  WHERE (o.valid_from >= @low AND o.valid_from < @high)
     OR (o.valid_to   >= @low AND o.valid_to   < @high);

  An update returns the ending and starting versions. A delete returns the ending
  version with no current_row. Bronze upserts by (id, valid_from), then derives
  OrderCurrent from the latest version for each changed id.
*/

CREATE OR ALTER PROCEDURE transformation.LoadProductDimension
    @RunId uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;

    UPDATE target
       SET target.ProductName        = source.ProductName,
           target.Category           = source.Category,
           target.ProductDescription = source.ProductDescription,
           target.BasePrice          = source.BasePrice,
           target.Currency           = UPPER(source.Currency),
           target.ValidToUtc         = source.SourceValidTo,
           target.IsCurrent          = IIF(source.SourceValidTo = '9999-12-31 23:59:59.999', 1, 0)
    FROM reporting.DimProduct AS target
    JOIN ingestion.ProductVersion AS source
      ON source.ProductId = target.ProductId
     AND source.SourceValidFrom = target.ValidFromUtc;

    INSERT reporting.DimProduct
        (ProductId, ProductName, Category, ProductDescription, BasePrice,
         Currency, ValidFromUtc, ValidToUtc, IsCurrent)
    SELECT source.ProductId, source.ProductName, source.Category,
           source.ProductDescription, source.BasePrice, UPPER(source.Currency),
           source.SourceValidFrom, source.SourceValidTo,
           IIF(source.SourceValidTo = '9999-12-31 23:59:59.999', 1, 0)
    FROM ingestion.ProductVersion AS source
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM reporting.DimProduct AS target
        WHERE target.ProductId = source.ProductId
          AND target.ValidFromUtc = source.SourceValidFrom
    );

    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE transformation.LoadCustomerDimension
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    UPDATE target
       SET target.CustomerName     = source.CustomerName,
           target.Email            = source.Email,
           target.Country          = source.Country,
           target.RegistrationDate = CONVERT(date, source.RegistrationDateUtc)
    FROM reporting.DimCustomer AS target
    JOIN ingestion.CustomerSnapshot AS source
      ON source.CustomerId = target.CustomerId;

    INSERT reporting.DimCustomer
        (CustomerId, CustomerName, Email, Country, RegistrationDate)
    SELECT source.CustomerId, source.CustomerName, source.Email, source.Country,
           CONVERT(date, source.RegistrationDateUtc)
    FROM ingestion.CustomerSnapshot AS source
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM reporting.DimCustomer AS target
        WHERE target.CustomerId = source.CustomerId
    );
END;
GO

CREATE OR ALTER VIEW transformation.vw_SalesReady
AS
SELECT
    o.OrderId,
    i.OrderItemId,
    CONVERT(int, CONVERT(char(8), CONVERT(date, o.OrderDateUtc), 112)) AS OrderDateKey,
    DATEPART(hour, o.OrderDateUtc) * 100 + DATEPART(minute, o.OrderDateUtc) AS OrderTimeKey,
    COALESCE(p.ProductKey, -1) AS ProductKey,
    COALESCE(c.CustomerKey, -1) AS CustomerKey,
    i.ProductId,
    i.Quantity,
    CAST(i.UnitPrice AS decimal(19,4)) AS UnitPriceOriginal,
    CONVERT(char(3), UPPER(i.Currency)) AS OriginalCurrency,
    fx.ConversionRate AS FxRateToUsd,
    CAST(i.UnitPrice * fx.ConversionRate AS decimal(19,4)) AS UnitPriceUsd,
    CAST(i.Quantity * i.UnitPrice * fx.ConversionRate AS decimal(19,4)) AS TotalAmountUsd,
    CASE
        WHEN o.IsDeleted = 1 OR LOWER(o.OrderStatus) <> 'completed' THEN 'ORDER_NOT_REPORTABLE'
        WHEN o.OrderDateUtc > SYSUTCDATETIME() THEN 'FUTURE_ORDER'
        WHEN i.Quantity <= 0 THEN 'INVALID_QUANTITY'
        WHEN i.UnitPrice <= 0 THEN 'INVALID_PRICE'
        WHEN fx.ConversionRate IS NULL THEN 'MISSING_OR_INVALID_FX'
        ELSE NULL
    END AS RejectReason
FROM ingestion.OrderItemSnapshot AS i
JOIN ingestion.OrderCurrent AS o
  ON o.OrderId = i.OrderId
LEFT JOIN reporting.DimProduct AS p
  ON p.ProductId = i.ProductId
 AND o.OrderDateUtc >= p.ValidFromUtc
 AND o.OrderDateUtc <  p.ValidToUtc
LEFT JOIN reporting.DimCustomer AS c
  ON c.CustomerId = o.CustomerId
LEFT JOIN ingestion.FxRate AS fx
  ON fx.RateDate = CONVERT(date, o.OrderDateUtc)
 AND fx.CurrencyFrom = UPPER(i.Currency)
 AND fx.CurrencyTo = 'USD';
GO

CREATE OR ALTER VIEW transformation.vw_OrderReconciliation
AS
WITH LineRollup AS
(
    SELECT
        i.OrderId,
        COUNT_BIG(*) AS LineCount,
        SUM(CASE WHEN UPPER(i.Currency) <> UPPER(o.HeaderCurrency) THEN 1 ELSE 0 END)
            AS CurrencyMismatchCount,
        SUM(CASE WHEN line_fx.ConversionRate IS NULL THEN 1 ELSE 0 END)
            AS MissingLineFxCount,
        SUM(CASE WHEN line_fx.ConversionRate IS NOT NULL
                 THEN i.Quantity * i.UnitPrice * line_fx.ConversionRate END)
            AS LineTotalUsd
    FROM ingestion.OrderItemSnapshot AS i
    JOIN ingestion.OrderCurrent AS o ON o.OrderId = i.OrderId
    LEFT JOIN ingestion.FxRate AS line_fx
      ON line_fx.RateDate = CONVERT(date, o.OrderDateUtc)
     AND line_fx.CurrencyFrom = UPPER(i.Currency)
     AND line_fx.CurrencyTo = 'USD'
    GROUP BY i.OrderId
)
SELECT
    o.OrderId,
    COALESCE(lines.LineCount, 0) AS LineCount,
    CONVERT(bit, IIF(lines.OrderId IS NULL, 1, 0)) AS HasNoLines,
    CONVERT(bit, IIF(COALESCE(lines.CurrencyMismatchCount, 0) > 0, 1, 0))
        AS HasCurrencyMismatch,
    CONVERT(bit, IIF(header_fx.ConversionRate IS NULL OR
                     COALESCE(lines.MissingLineFxCount, 0) > 0, 1, 0)) AS HasMissingFx,
    CAST(o.HeaderTotal * header_fx.ConversionRate AS decimal(19,4)) AS HeaderTotalUsd,
    CAST(lines.LineTotalUsd AS decimal(19,4)) AS LineTotalUsd,
    CONVERT(bit, IIF(
        header_fx.ConversionRate IS NOT NULL
        AND COALESCE(lines.MissingLineFxCount, 0) = 0
        AND lines.OrderId IS NOT NULL
        AND ABS(o.HeaderTotal * header_fx.ConversionRate - lines.LineTotalUsd) > 0.01,
        1, 0)) AS HasAmountMismatch
FROM ingestion.OrderCurrent AS o
LEFT JOIN LineRollup AS lines ON lines.OrderId = o.OrderId
LEFT JOIN ingestion.FxRate AS header_fx
  ON header_fx.RateDate = CONVERT(date, o.OrderDateUtc)
 AND header_fx.CurrencyFrom = UPPER(o.HeaderCurrency)
 AND header_fx.CurrencyTo = 'USD'
WHERE o.IsDeleted = 0;
GO

CREATE OR ALTER PROCEDURE transformation.LoadSalesFact
    @RunId uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;

    INSERT ingestion.ErrorLog
        (RunId, Severity, SourceObject, SourceKey, ErrorCode, ErrorDetail)
    SELECT @RunId, 'ERROR', 'sales.order_items', CONVERT(varchar(20), OrderItemId),
           RejectReason, CONCAT('Order ', OrderId, ' was not published')
    FROM transformation.vw_SalesReady
    WHERE RejectReason IS NOT NULL
      AND RejectReason <> 'ORDER_NOT_REPORTABLE';

    /* The snapshot has already passed completeness and duplicate checks. */
    DELETE target
    FROM reporting.FactSales AS target
    LEFT JOIN transformation.vw_SalesReady AS source
      ON source.OrderId = target.OrderId
     AND source.OrderItemId = target.OrderItemId
     AND source.RejectReason IS NULL
    WHERE source.OrderItemId IS NULL;

    UPDATE target
       SET target.OrderDateKey      = source.OrderDateKey,
           target.OrderTimeKey      = source.OrderTimeKey,
           target.ProductKey        = source.ProductKey,
           target.CustomerKey       = source.CustomerKey,
           target.Quantity          = source.Quantity,
           target.UnitPriceOriginal = source.UnitPriceOriginal,
           target.OriginalCurrency  = source.OriginalCurrency,
           target.FxRateToUsd       = source.FxRateToUsd,
           target.UnitPriceUsd      = source.UnitPriceUsd,
           target.TotalAmountUsd    = source.TotalAmountUsd,
           target.LoadRunId         = @RunId,
           target.LoadedAtUtc       = SYSUTCDATETIME()
    FROM reporting.FactSales AS target
    JOIN transformation.vw_SalesReady AS source
      ON source.OrderId = target.OrderId
     AND source.OrderItemId = target.OrderItemId
    WHERE source.RejectReason IS NULL;

    INSERT reporting.FactSales
        (OrderDateKey, OrderTimeKey, ProductKey, CustomerKey, OrderId,
         OrderItemId, Quantity, UnitPriceOriginal, OriginalCurrency,
         FxRateToUsd, UnitPriceUsd, TotalAmountUsd, LoadRunId)
    SELECT source.OrderDateKey, source.OrderTimeKey, source.ProductKey,
           source.CustomerKey, source.OrderId, source.OrderItemId,
           source.Quantity, source.UnitPriceOriginal, source.OriginalCurrency,
           source.FxRateToUsd, source.UnitPriceUsd, source.TotalAmountUsd, @RunId
    FROM transformation.vw_SalesReady AS source
    WHERE source.RejectReason IS NULL
      AND NOT EXISTS
      (
          SELECT 1
          FROM reporting.FactSales AS target
          WHERE target.OrderId = source.OrderId
            AND target.OrderItemId = source.OrderItemId
      );

    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER VIEW reporting.vw_ProductPerformance
AS
SELECT
    p.ProductId,
    p.ProductName,
    p.Category,
    SUM(f.Quantity) AS UnitsSold,
    COUNT(DISTINCT f.OrderId) AS OrderCount,
    SUM(f.TotalAmountUsd) AS RevenueUsd
FROM reporting.FactSales AS f
JOIN reporting.DimProduct AS p ON p.ProductKey = f.ProductKey
GROUP BY p.ProductId, p.ProductName, p.Category;
GO

CREATE OR ALTER VIEW reporting.vw_DemandByTime
AS
SELECT
    d.DayOfWeekNumber,
    d.DayOfWeekName,
    t.Hour24,
    t.TimeOfDayBucket,
    COUNT(DISTINCT f.OrderId) AS OrderCount,
    SUM(f.Quantity) AS UnitsSold,
    SUM(f.TotalAmountUsd) AS RevenueUsd,
    CAST(SUM(f.TotalAmountUsd) /
         NULLIF(COUNT(DISTINCT f.OrderId), 0) AS decimal(19,2)) AS AverageOrderValueUsd
FROM reporting.FactSales AS f
JOIN reporting.DimDate AS d ON d.DateKey = f.OrderDateKey
JOIN reporting.DimTime AS t ON t.TimeKey = f.OrderTimeKey
GROUP BY d.DayOfWeekNumber, d.DayOfWeekName, t.Hour24, t.TimeOfDayBucket;
GO

/* Called only after all load procedures and reconciliation checks succeed. */
CREATE OR ALTER PROCEDURE ingestion.AdvanceWatermark
    @SourceObject       varchar(128),
    @ExpectedPreviousUtc datetime2(3),
    @ExtractUpperUtc    datetime2(3),
    @RunId              uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @ExtractUpperUtc <= @ExpectedPreviousUtc
        THROW 50001, 'The new watermark must be later than the previous watermark.', 1;

    UPDATE ingestion.Watermark
       SET LastSuccessfulUtc = @ExtractUpperUtc,
           LastRunId = @RunId
     WHERE SourceObject = @SourceObject
       AND LastSuccessfulUtc = @ExpectedPreviousUtc;

    IF @@ROWCOUNT <> 1
        THROW 50002, 'Watermark changed or source object was not initialized.', 1;
END;
GO
