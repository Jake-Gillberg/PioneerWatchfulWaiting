#' @export
runStudy <- function(connectionDetails = NULL,
                     connection = NULL,
                     cdmDatabaseSchema,
                     oracleTempSchema = NULL,
                     cohortDatabaseSchema,
                     cohortStagingTable = "cohort_stg",
                     cohortTable = "cohort",
                     featureSummaryTable = "cohort_smry",
                     cohortIdsToExcludeFromExecution = c(),
                     cohortIdsToExcludeFromResultsExport = NULL,
                     cohortGroups = getUserSelectableCohortGroups(),
                     exportFolder,
                     databaseId,
                     databaseName = databaseId,
                     databaseDescription = "",
                     useBulkCharacterization = FALSE,
                     minCellCount = 5,
                     incremental = TRUE,
                     incrementalFolder = file.path(exportFolder, "RecordKeeping")) {
  
  start <- Sys.time()
  
  if (!file.exists(exportFolder)) {
    dir.create(exportFolder, recursive = TRUE)
  }
  
  ParallelLogger::addDefaultFileLogger(file.path(exportFolder, "PioneerWatchfulWaiting.txt"))
  on.exit(ParallelLogger::unregisterLogger("DEFAULT"))
  
  # Write out the system information
  ParallelLogger::logInfo(.systemInfo())
  
  useSubset = Sys.getenv("USE_SUBSET")
  if (!is.na(as.logical(useSubset)) && as.logical(useSubset)) {
    ParallelLogger::logWarn("Running in subset mode for testing")
  }
  
  if (incremental) {
    if (is.null(incrementalFolder)) {
      stop("Must specify incrementalFolder when incremental = TRUE")
    }
    if (!file.exists(incrementalFolder)) {
      dir.create(incrementalFolder, recursive = TRUE)
    }
  }
  
  if (!is.null(getOption("fftempdir")) && !file.exists(getOption("fftempdir"))) {
    warning("fftempdir '", getOption("fftempdir"), "' not found. Attempting to create folder")
    dir.create(getOption("fftempdir"), recursive = TRUE)
  }
  
  if (is.null(connection)) {
    connection <- DatabaseConnector::connect(connectionDetails)
    on.exit(DatabaseConnector::disconnect(connection))
  }
  
  # Instantiate cohorts -----------------------------------------------------------------------
  cohorts <- getCohortsToCreate()
  # Remove any cohorts that are to be excluded
  cohorts <- cohorts[!(cohorts$cohortId %in% cohortIdsToExcludeFromExecution), ]
  targetCohortIds <- cohorts[cohorts$cohortType %in% cohortGroups, "cohortId"][[1]]
  strataCohortIds <- cohorts[cohorts$cohortType == "strata", "cohortId"][[1]]
  # featureCohortIds <- cohorts[cohorts$cohortType == "feature", "cohortId"][[1]]
  featureCohortIds <- cohorts[cohorts$cohortType == "outcome", "cohortId"][[1]]
  
  # Start with the target cohorts
  ParallelLogger::logInfo("**********************************************************")
  ParallelLogger::logInfo("  ---- Creating target cohorts ---- ")
  ParallelLogger::logInfo("**********************************************************")
  instantiateCohortSet(connectionDetails = connectionDetails,
                       connection = connection,
                       cdmDatabaseSchema = cdmDatabaseSchema,
                       oracleTempSchema = oracleTempSchema,
                       cohortDatabaseSchema = cohortDatabaseSchema,
                       cohortTable = cohortStagingTable,
                       cohortIds = targetCohortIds,
                       minCellCount = minCellCount,
                       createCohortTable = TRUE,
                       generateInclusionStats = FALSE,
                       incremental = incremental,
                       incrementalFolder = incrementalFolder,
                       inclusionStatisticsFolder = exportFolder)
  
  # Next do the strata cohorts
  ParallelLogger::logInfo("******************************************")
  ParallelLogger::logInfo("  ---- Creating strata cohorts  ---- ")
  ParallelLogger::logInfo("******************************************")
  instantiateCohortSet(connectionDetails = connectionDetails,
                       connection = connection,
                       cdmDatabaseSchema = cdmDatabaseSchema,
                       oracleTempSchema = oracleTempSchema,
                       cohortDatabaseSchema = cohortDatabaseSchema,
                       cohortTable = cohortStagingTable,
                       cohortIds = strataCohortIds,
                       minCellCount = minCellCount,
                       createCohortTable = FALSE,
                       generateInclusionStats = FALSE,
                       incremental = incremental,
                       incrementalFolder = incrementalFolder,
                       inclusionStatisticsFolder = exportFolder)
  
  # Create the feature cohorts
  ParallelLogger::logInfo("**********************************************************")
  ParallelLogger::logInfo(" ---- Creating feature cohorts ---- ")
  ParallelLogger::logInfo("**********************************************************")
  instantiateCohortSet(connectionDetails = connectionDetails,
                       connection = connection,
                       cdmDatabaseSchema = cdmDatabaseSchema,
                       oracleTempSchema = oracleTempSchema,
                       cohortDatabaseSchema = cohortDatabaseSchema,
                       cohortTable = cohortStagingTable,
                       cohortIds = featureCohortIds,
                       minCellCount = minCellCount,
                       createCohortTable = FALSE,
                       generateInclusionStats = FALSE,
                       incremental = incremental,
                       incrementalFolder = incrementalFolder,
                       inclusionStatisticsFolder = exportFolder)
  
  # Create the stratified cohorts
  ParallelLogger::logInfo("**********************************************************")
  ParallelLogger::logInfo(" ---- Creating stratified target cohorts ---- ")
  ParallelLogger::logInfo("**********************************************************")
  createBulkStrata(connection = connection,
                   cdmDatabaseSchema = cdmDatabaseSchema,
                   cohortDatabaseSchema = cohortDatabaseSchema,
                   cohortStagingTable = cohortStagingTable,
                   targetIds = targetCohortIds,
                   oracleTempSchema = oracleTempSchema)
  
  # Copy and censor cohorts to the final table
  ParallelLogger::logInfo("**********************************************************")
  ParallelLogger::logInfo(" ---- Copy cohorts to main table ---- ")
  ParallelLogger::logInfo("**********************************************************")
  copyAndCensorCohorts(connection = connection,
                       cohortDatabaseSchema = cohortDatabaseSchema,
                       cohortStagingTable = cohortStagingTable,
                       cohortTable = cohortTable,
                       minCellCount = minCellCount,
                       targetIds = targetCohortIds,
                       oracleTempSchema = oracleTempSchema)
  
  # Compute the features
  ParallelLogger::logInfo("**********************************************************")
  ParallelLogger::logInfo(" ---- Create feature proportions ---- ")
  ParallelLogger::logInfo("**********************************************************")
  createFeatureProportions(connection = connection,
                           cohortDatabaseSchema = cohortDatabaseSchema,
                           cohortStagingTable = cohortStagingTable,
                           cohortTable = cohortTable,
                           featureSummaryTable = featureSummaryTable,
                           oracleTempSchema = oracleTempSchema)
  
  ParallelLogger::logInfo("Saving database metadata")
  database <- data.frame(databaseId = databaseId,
                         databaseName = databaseName,
                         description = databaseDescription,
                         vocabularyVersion = getVocabularyInfo(connection = connection,
                                                               cdmDatabaseSchema = cdmDatabaseSchema,
                                                               oracleTempSchema = oracleTempSchema),
                         isMetaAnalysis = 0)
  writeToCsv(database, file.path(exportFolder, "database.csv"))
  
  # Counting staging cohorts ---------------------------------------------------------------
  ParallelLogger::logInfo("Counting staging cohorts")
  counts <- getCohortCounts(connection = connection,
                            cohortDatabaseSchema = cohortDatabaseSchema,
                            cohortTable = cohortStagingTable)
  if (nrow(counts) > 0) {
    counts$databaseId <- databaseId
    counts <- enforceMinCellValue(counts, "cohortEntries", minCellCount)
    counts <- enforceMinCellValue(counts, "cohortSubjects", minCellCount)
  }
  allStudyCohorts <- getAllStudyCohorts()
  counts <- dplyr::left_join(x = allStudyCohorts, y = counts, by="cohortId")
  writeToCsv(counts, file.path(exportFolder, "cohort_staging_count.csv"), incremental = incremental, cohortId = counts$cohortId)

  # Generate survival info -----------------------------------------------------------------
  ParallelLogger::logInfo("Generating time to event data")
  targetIds <- allStudyCohorts[[2]]
  targetIds <- setdiff(targetIds, featureCohortIds)
  targetIds <- setdiff(targetIds, strataCohortIds)
  KMOutcomes <- getFeatures()
  # KMOutcomesIds <- KMOutcomes$cohortId[KMOutcomes$createKMPlot == TRUE]
  KMOutcomesIds <- KMOutcomes$cohortId
  timeToEvent <- generateSurvival(connection, cohortDatabaseSchema, cohortTable = cohortStagingTable,
                                  targetIds = targetIds, outcomeIds = KMOutcomesIds, databaseId = databaseId, packageName = getThisPackageName())


  KMOutcomesIds <- KMOutcomes$cohortId[KMOutcomes$name %in% c('Death', 'Symptomatic progression')]
  combinedOutcomeId <- max(allStudyCohorts$cohortId) + 1
  timeToCombinedEvent <- generateCombinedSurvival(connection, cohortDatabaseSchema, cohortTable = cohortStagingTable,
                                                  targetIds = targetIds, outcomeIds = KMOutcomesIds,
                                                  combinedOutcomeId = combinedOutcomeId, databaseId = databaseId, packageName = getThisPackageName())
  timeToEvent <- rbind(timeToEvent, timeToCombinedEvent)


  writeToCsv(timeToEvent, file.path(exportFolder, "cohort_time_to_event.csv"), incremental = incremental, targetId = timeToEvent$targetId)


  # Generate metricsDistribution info -----------------------------------------------------
  ParallelLogger::logInfo("Generating metrics distribution")


  # prepare necessary tables
  targetIdsFormatted <- paste(targetIds, collapse = ', ')
  pathToSql <- system.file("sql", "sql_server","quartiles", "IQRComplementaryTables.sql", package = getThisPackageName())
  sql <- readChar(pathToSql, file.info(pathToSql)$size)
  DatabaseConnector::renderTranslateExecuteSql(connection,
                                               sql = sql,
                                               cdm_database_schema = cdmDatabaseSchema,
                                               cohort_database_schema = cohortDatabaseSchema,
                                               cohort_table = cohortStagingTable,
                                               target_ids = targetIdsFormatted)
  
  outcomeBasedAnalyses <- c('TimeToDeath', 'TimeToSymptomaticProgression', 'TimeToTreatmentInitiation')
  DistribAnalyses <- c('AgeAtDiagnosis', 'YearOfDiagnosis', 'CharlsonAtDiagnosis', 'PsaAtDiagnosis', outcomeBasedAnalyses)
  outcomes <- getFeatures()
  
  metricsDistribution <- data.frame()
  
  for(analysis in DistribAnalyses){
    outcome <- gsub("TimeTo", "", analysis)
    outcome <- substring(SqlRender::camelCaseToTitleCase(outcome), 2)
    outcomeId <- outcomes[tolower(outcomes$name) == tolower(outcome), "cohortId"][[1]]
    
    if (length(outcomeId) == 0 & analysis %in% outcomeBasedAnalyses){
      next
    }
    
    result <- getAtEventDistribution(connection, cohortDatabaseSchema, cdmDatabaseSchema, cohortTable = cohortStagingTable,
                                     targetIds = targetIds, outcomeId = outcomeId, databaseId = databaseId, 
                                     packageName = getThisPackageName(), analysisName <- analysis)
    metricsDistribution<- rbind(metricsDistribution, result)
  }
  
   writeToCsv(metricsDistribution, file.path(exportFolder, "metrics_distribution.csv"), incremental = incremental,
             cohortDefinitionId = metricsDistribution$cohortDefinitionId)
   
   pathToSql <- system.file("sql", "sql_server","quartiles", "RemoveComplementaryTables.sql", package = getThisPackageName())
   sql <- readChar(pathToSql, file.info(pathToSql)$size)
   DatabaseConnector::renderTranslateExecuteSql(connection,
                                                sql = sql,
                                                cohort_database_schema = cohortDatabaseSchema
                                                )

  
  # Counting cohorts -----------------------------------------------------------------------
  ParallelLogger::logInfo("Counting cohorts")
  counts <- getCohortCounts(connection = connection,
                            cohortDatabaseSchema = cohortDatabaseSchema,
                            cohortTable = cohortTable)
  if (nrow(counts) > 0) {
    counts$databaseId <- databaseId
    counts <- enforceMinCellValue(counts, "cohortEntries", minCellCount)
    counts <- enforceMinCellValue(counts, "cohortSubjects", minCellCount)
  }
  writeToCsv(counts, file.path(exportFolder, "cohort_count.csv"), incremental = incremental, cohortId = counts$cohortId)
  
  # Read in the cohort counts
  counts <- readr::read_csv(file.path(exportFolder, "cohort_count.csv"), col_types = readr::cols())
  colnames(counts) <- SqlRender::snakeCaseToCamelCase(colnames(counts))
  
  # Export the cohorts from the study
  cohortsForExport <- loadCohortsForExportFromPackage(cohortIds = counts$cohortId)
  writeToCsv(cohortsForExport, file.path(exportFolder, "cohort.csv"))
  
  # Extract feature counts -----------------------------------------------------------------------
  ParallelLogger::logInfo("Extract feature counts")
  featureProportions <- exportFeatureProportions(connection = connection,
                                                 cohortDatabaseSchema = cohortDatabaseSchema,
                                                 cohortTable = cohortTable,
                                                 featureSummaryTable = featureSummaryTable)
  if (nrow(featureProportions) > 0) {
    featureProportions$databaseId <- databaseId
    featureProportions <- enforceMinCellValue(featureProportions, "featureCount", minCellCount)
    featureProportions <- featureProportions[featureProportions$totalCount >= getMinimumSubjectCountForCharacterization(), ]
  }
  features <- formatCovariates(featureProportions)
  writeToCsv(features, file.path(exportFolder, "covariate.csv"), incremental = incremental, covariateId = features$covariateId)
  featureValues <- formatCovariateValues(featureProportions, counts, minCellCount, databaseId)
  featureValues <- featureValues[,c("cohortId", "covariateId", "mean", "sd", "databaseId")]
  writeToCsv(featureValues, file.path(exportFolder, "covariate_value.csv"), incremental = incremental, cohortId = featureValues$cohortId, covariateId = featureValues$covariateId)
  # Also keeping a raw output for debugging
  writeToCsv(featureProportions, file.path(exportFolder, "feature_proportions.csv"))
  
  # Cohort characterization ---------------------------------------------------------------
  # Note to package maintainer: If any of the logic to this changes, you'll need to revist
  # the function createBulkCharacteristics
  runCohortCharacterization <- function(cohortId, cohortName, covariateSettings, windowId, curIndex, totalCount) {
    ParallelLogger::logInfo("- (windowId=", windowId, ", ", curIndex, " of ", totalCount, ") Creating characterization for cohort: ", cohortName)
    data <- getCohortCharacteristics(connection = connection,
                                     cdmDatabaseSchema = cdmDatabaseSchema,
                                     oracleTempSchema = oracleTempSchema,
                                     cohortDatabaseSchema = cohortDatabaseSchema,
                                     cohortTable = cohortTable,
                                     cohortId = cohortId,
                                     covariateSettings = covariateSettings)
    if (nrow(data) > 0) {
      data$cohortId <- cohortId
    }
    
    data$covariateId <- data$covariateId * 10 + windowId
    return(data)
  }
  
  # Subset the cohorts to the target/strata for running feature extraction
  # that are >= 140 per protocol to improve efficency
  featureExtractionCohorts <-  loadCohortsForExportWithChecksumFromPackage(counts[counts$cohortSubjects >= getMinimumSubjectCountForCharacterization(), c("cohortId")]$cohortId)
  # Bulk approach ----------------------
  if (useBulkCharacterization) {
    ParallelLogger::logInfo("********************************************************************************************")
    ParallelLogger::logInfo("Bulk characterization of all cohorts for all time windows")
    ParallelLogger::logInfo("********************************************************************************************")
    createBulkCharacteristics(connection, 
                              oracleTempSchema, 
                              cohortIds = featureExtractionCohorts$cohortId, 
                              cdmDatabaseSchema, 
                              cohortDatabaseSchema, 
                              cohortTable)
    writeBulkCharacteristics(connection, oracleTempSchema, counts, minCellCount, databaseId, exportFolder)
  } else {
    # Sequential Approach --------------------------------
    if (incremental) {
      recordKeepingFile <- file.path(incrementalFolder, "CreatedAnalyses.csv")
    }
    featureTimeWindows <- getFeatureTimeWindows()
    for (i in 1:nrow(featureTimeWindows)) {
      windowStart <- featureTimeWindows$windowStart[i]
      windowEnd <- featureTimeWindows$windowEnd[i]
      windowId <- featureTimeWindows$windowId[i]
      ParallelLogger::logInfo("********************************************************************************************")
      ParallelLogger::logInfo(paste0("Characterize concept features for start: ", windowStart, ", end: ", windowEnd, " (windowId=", windowId, ")"))
      ParallelLogger::logInfo("********************************************************************************************")
      createDemographics <- (i == 1)
      covariateSettings <- FeatureExtraction::createCovariateSettings(useDemographicsGender = createDemographics,
                                                                      useDemographicsAgeGroup = createDemographics,
                                                                      useConditionGroupEraShortTerm = TRUE,
                                                                      useDrugGroupEraShortTerm = TRUE,
                                                                      shortTermStartDays = windowStart,
                                                                      endDays = windowEnd)
      task <- paste0("runCohortCharacterizationWindowId", windowId)
      if (incremental) {
        subset <- subsetToRequiredCohorts(cohorts = featureExtractionCohorts,
                                          task = task,
                                          incremental = incremental,
                                          recordKeepingFile = recordKeepingFile)
      } else {
        subset <- featureExtractionCohorts
      }
      
      if (nrow(subset) > 0) {
        for (j in 1:nrow(subset)) {
          data <- runCohortCharacterization(cohortId = subset$cohortId[j],
                                            cohortName = subset$cohortName[j],
                                            covariateSettings = covariateSettings,
                                            windowId = windowId,
                                            curIndex = j,
                                            totalCount = nrow(subset))
          covariates <- formatCovariates(data)
          writeToCsv(covariates, file.path(exportFolder, "covariate.csv"), incremental = incremental, covariateId = covariates$covariateId)
          data <- formatCovariateValues(data, counts, minCellCount, databaseId)
          writeToCsv(data, file.path(exportFolder, "covariate_value.csv"), incremental = incremental, cohortId = data$cohortId, data$covariateId)
          if (incremental) {
            recordTasksDone(cohortId = subset$cohortId[j],
                            task = task,
                            checksum = subset$checksum[j],
                            recordKeepingFile = recordKeepingFile,
                            incremental = incremental)
          }
        }
      }
    }
  }
  
  # Format results -----------------------------------------------------------------------------------
  ParallelLogger::logInfo("********************************************************************************************")
  ParallelLogger::logInfo("Formatting Results")
  ParallelLogger::logInfo("********************************************************************************************")
  # Ensure that the covariate_value.csv is free of any duplicative values. This can happen after more than
  # one run of the package.
  cv <- data.table::fread(file.path(exportFolder, "covariate_value.csv"))
  cv <- unique(cv)
  writeToCsv(cv, file.path(exportFolder, "covariate_value.csv"), incremental = FALSE)
  
  # Export to zip file -------------------------------------------------------------------------------
  exportResults(exportFolder, databaseId, cohortIdsToExcludeFromResultsExport)
  delta <- Sys.time() - start
  ParallelLogger::logInfo(paste("Running study took",
                                signif(delta, 3),
                                attr(delta, "units")))
}

#' @export
exportResults <- function(exportFolder, databaseId, cohortIdsToExcludeFromResultsExport = NULL) {
  filesWithCohortIds <- c("covariate_value.csv","cohort_count.csv")
  tempFolder <- NULL
  ParallelLogger::logInfo("Adding results to zip file")
  if (!is.null(cohortIdsToExcludeFromResultsExport)) {
    ParallelLogger::logInfo("Exclude cohort ids: ", paste(cohortIdsToExcludeFromResultsExport, collapse = ", "))
    # Copy files to temp location to remove the cohorts to remove
    tempFolder <- file.path(exportFolder, "temp")
    files <- list.files(exportFolder, pattern = ".*\\.csv$")
    if (!file.exists(tempFolder)) {
      dir.create(tempFolder)
    }
    file.copy(file.path(exportFolder, files), tempFolder)
    
    # Censor out the cohorts based on the IDs passed in
    for(i in 1:length(filesWithCohortIds)) {
      fileName <- file.path(tempFolder, filesWithCohortIds[i])
      fileContents <- readr::read_csv(fileName, col_types = readr::cols())
      fileContents <- fileContents[!(fileContents$cohort_id %in% cohortIdsToExcludeFromResultsExport),]
      readr::write_csv(fileContents, fileName)
    }
    
    # Zip the results and copy to the main export folder
    zipName <- zipResults(tempFolder, databaseId)
    file.copy(zipName, exportFolder)
    unlink(tempFolder, recursive = TRUE)
    zipName <- file.path(exportFolder, basename(zipName))
  } else {
    zipName <- zipResults(exportFolder, databaseId)
  }
  ParallelLogger::logInfo("Results are ready for sharing at:", zipName)
}

zipResults <- function(exportFolder, databaseId) {
  
  date <- format(Sys.time(), "%Y%m%dT%H%M%S")
  zipName <- file.path(exportFolder, paste0("Results_v", getThisPackageVersion(), "_", databaseId, "_", date, ".zip")) 
  files <- list.files(exportFolder, ".*\\.csv$")
  oldWd <- setwd(exportFolder)
  on.exit(setwd(oldWd), add = TRUE)
  DatabaseConnector::createZipFile(zipFile = zipName, files = files)
  return(zipName)
}

# Per protocol, we will only characterize cohorts with
# >= 140 subjects to improve efficency
getMinimumSubjectCountForCharacterization <- function() {
  return(140)
}

getVocabularyInfo <- function(connection, cdmDatabaseSchema, oracleTempSchema) {
  sql <- "SELECT vocabulary_version FROM @cdm_database_schema.vocabulary WHERE vocabulary_id = 'None';"
  sql <- SqlRender::render(sql, cdm_database_schema = cdmDatabaseSchema)
  sql <- SqlRender::translate(sql, targetDialect = attr(connection, "dbms"), oracleTempSchema = oracleTempSchema)
  vocabInfo <- DatabaseConnector::querySql(connection, sql)
  return(vocabInfo[[1]])
}

#' @export
getUserSelectableCohortGroups <- function() {
  cohortGroups <- getCohortGroups()
  return(unlist(cohortGroups[cohortGroups$userCanSelect == TRUE, c("cohortGroup")], use.names = FALSE))
}

formatCovariates <- function(data) {
  # Drop covariates with mean = 0 after rounding to 4 digits:
  if (nrow(data) > 0) {
    data <- data[round(data$mean, 4) != 0, ]
    covariates <- unique(data.table::setDT(data[, c("covariateId", "covariateName", "analysisId")]))
    colnames(covariates)[[3]] <- "covariateAnalysisId"
  } else {
    covariates <- data.table::data.table("covariateId" = integer(), "covariateName" = character(), "covariateAnalysisId" = integer())
  }
  return(covariates)
}

formatCovariateValues <- function(data, counts, minCellCount, databaseId) {
  data$covariateName <- NULL
  data$analysisId <- NULL
  if (nrow(data) > 0) {
    data$databaseId <- databaseId
    data <- merge(data, counts[, c("cohortId", "cohortEntries")])
    data <- enforceMinCellValue(data, "mean", minCellCount/data$cohortEntries)
    data$sd[data$mean < 0] <- NA
    data$cohortEntries <- NULL
    data$mean <- round(data$mean, 3)
    data$sd <- round(data$sd, 3)
  }
  return(data)  
}

loadCohortsFromPackage <- function(cohortIds) {
  packageName = getThisPackageName()
  cohorts <- getCohortsToCreate()
  cohorts <- cohorts %>%  dplyr::mutate(atlasId = NULL)
  if (!is.null(cohortIds)) {
    cohorts <- cohorts[cohorts$cohortId %in% cohortIds, ]
  }
  if ("atlasName" %in% colnames(cohorts)) {
    # Remove PIONEER cohort identifier (3.g. [PIONEER O2])
    cohorts <- cohorts %>% 
      dplyr::mutate(cohortName = trimws(gsub("(\\[.+?\\])", "", atlasName)),
                    cohortFullName = atlasName) %>%
      dplyr::select(-atlasName, -name)
  } else {
    cohorts <- cohorts %>% dplyr::rename(cohortName = name, cohortFullName = fullName)
  }
  
  getSql <- function(name) {
    pathToSql <- system.file("sql", "sql_server", paste0(name, ".sql"), package = packageName, mustWork = TRUE)
    sql <- readChar(pathToSql, file.info(pathToSql)$size)
    return(sql)
  }
  cohorts$sql <- sapply(cohorts$cohortId, getSql)
  getJson <- function(name) {
    pathToJson <- system.file("cohorts", paste0(name, ".json"), package = packageName, mustWork = TRUE)
    json <- readChar(pathToJson, file.info(pathToJson)$size)
    return(json)
  }
  cohorts$json <- sapply(cohorts$cohortId, getJson)
  return(cohorts)
}

loadCohortsForExportFromPackage <- function(cohortIds) {
  packageName = getThisPackageName()
  cohorts <- getCohortsToCreate()
  cohorts <- cohorts %>%  dplyr::mutate(atlasId = NULL)
  if ("atlasName" %in% colnames(cohorts)) {
    # Remove PIONEER cohort identifier (3.g. [PIONEER O2])
    # Remove atlasName and name from object to prevent clashes when combining with stratXref
    cohorts <- cohorts %>% 
      dplyr::mutate(cohortName = trimws(gsub("(\\[.+?\\])", "", atlasName)),
                    cohortFullName = atlasName) %>%
      dplyr::select(-atlasName, -name)
  } else {
    cohorts <- cohorts %>% dplyr::rename(cohortName = name, cohortFullName = fullName)
  }
  
  # Get the stratified cohorts for the study
  # and join to the cohorts to create to get the names
  targetStrataXref <- getTargetStrataXref() 
  targetStrataXref <- targetStrataXref %>% 
    dplyr::rename(cohortName = name) %>%
    dplyr::mutate(cohortFullName = cohortName,
                  targetId = NULL,
                  strataId = NULL)
  
  cols <- names(cohorts)
  cohorts <- rbind(cohorts, targetStrataXref[cols])
  
  if (!is.null(cohortIds)) {
    cohorts <- cohorts[cohorts$cohortId %in% cohortIds, ]
  }
  
  return(cohorts)
}

loadCohortsForExportWithChecksumFromPackage <- function(cohortIds) {
  packageName = getThisPackageName()
  strata <- getAllStrata()
  targetStrataXref <- getTargetStrataXref()
  cohorts <- loadCohortsForExportFromPackage(cohortIds)
  
  # Match up the cohorts in the study w/ the targetStrataXref and 
  # set the target/strata columns
  cohortsWithStrata <- dplyr::left_join(cohorts, targetStrataXref, by="cohortId")
  cohortsWithStrata <- dplyr::rename(cohortsWithStrata, cohortType = "cohortType.x")
  cohortsWithStrata$targetId <- ifelse(is.na(cohortsWithStrata$targetId), cohortsWithStrata$cohortId, cohortsWithStrata$targetId)
  cohortsWithStrata$strataId <- ifelse(is.na(cohortsWithStrata$strataId), 0, cohortsWithStrata$strataId)
  
  getChecksum <- function(targetId, strataId, cohortType) {
    pathToSql <- system.file("sql", "sql_server", paste0(targetId, ".sql"), package = packageName, mustWork = TRUE)
    sql <- readChar(pathToSql, file.info(pathToSql)$size)
    if (strataId > 0) {
      sqlFileName <- strata[strata$cohortId == strataId, c("generationScript")][[1]]
      pathToSql <- system.file("sql", "sql_server", sqlFileName, package = packageName, mustWork = TRUE)
      strataSql <- readChar(pathToSql, file.info(pathToSql)$size)
      sql <- paste(sql, strataSql, cohortType)
    }
    checksum <- computeChecksum(sql)
    return(checksum)
  }
  cohortsWithStrata$checksum <- mapply(getChecksum, 
                                       cohortsWithStrata$targetId, 
                                       strataId = cohortsWithStrata$strataId, 
                                       cohortType = cohortsWithStrata$cohortType)
  
  if (!is.null(cohortIds)) {
    cohortsWithStrata <- cohortsWithStrata[cohortsWithStrata$cohortId %in% cohortIds, ]
  }
  
  return(cohortsWithStrata)
}

writeToCsv <- function(data, fileName, incremental = FALSE, ...) {
  colnames(data) <- SqlRender::camelCaseToSnakeCase(colnames(data))
  if (incremental) {
    params <- list(...)
    names(params) <- SqlRender::camelCaseToSnakeCase(names(params))
    params$data = data
    params$fileName = fileName
    do.call(saveIncremental, params)
  } else {
    readr::write_csv(data, fileName)
  }
}

enforceMinCellValue <- function(data, fieldName, minValues, silent = FALSE) {
  toCensor <- !is.na(data[, fieldName]) & data[, fieldName] < minValues & data[, fieldName] != 0
  if (!silent) {
    percent <- round(100 * sum(toCensor)/nrow(data), 1)
    ParallelLogger::logInfo("   censoring ",
                            sum(toCensor),
                            " values (",
                            percent,
                            "%) from ",
                            fieldName,
                            " because value below minimum")
  }
  if (length(minValues) == 1) {
    data[toCensor, fieldName] <- -minValues
  } else {
    data[toCensor, fieldName] <- -minValues[toCensor]
  }
  return(data)
}

getCohortCounts <- function(connectionDetails = NULL,
                            connection = NULL,
                            cohortDatabaseSchema,
                            cohortTable = "cohort",
                            cohortIds = c()) {
  start <- Sys.time()
  
  if (is.null(connection)) {
    connection <- DatabaseConnector::connect(connectionDetails)
    on.exit(DatabaseConnector::disconnect(connection))
  }
  sql <- SqlRender::loadRenderTranslateSql(sqlFilename = "CohortCounts.sql",
                                           packageName = getThisPackageName(),
                                           dbms = connection@dbms,
                                           cohort_database_schema = cohortDatabaseSchema,
                                           cohort_table = cohortTable,
                                           cohort_ids = cohortIds)
  counts <- DatabaseConnector::querySql(connection, sql, snakeCaseToCamelCase = TRUE)
  delta <- Sys.time() - start
  ParallelLogger::logInfo(paste("Counting cohorts took",
                                signif(delta, 3),
                                attr(delta, "units")))
  return(counts)
  
}

subsetToRequiredCohorts <- function(cohorts, task, incremental, recordKeepingFile) {
  if (incremental) {
    tasks <- getRequiredTasks(cohortId = cohorts$cohortId,
                              task = task,
                              checksum = cohorts$checksum,
                              recordKeepingFile = recordKeepingFile)
    return(cohorts[cohorts$cohortId %in% tasks$cohortId, ])
  } else {
    return(cohorts)
  }
}

getKeyIndex <- function(key, recordKeeping) {
  if (nrow(recordKeeping) == 0 || length(key[[1]]) == 0 || !all(names(key) %in% names(recordKeeping))) {
    return(c())
  } else {
    key <- unique(tibble::as_tibble(key))
    recordKeeping$idxCol <- 1:nrow(recordKeeping)
    idx <- merge(recordKeeping, key)$idx
    return(idx)
  }
}

recordTasksDone <- function(..., checksum, recordKeepingFile, incremental = TRUE) {
  if (!incremental) {
    return()
  }
  if (length(list(...)[[1]]) == 0) {
    return()
  }
  if (file.exists(recordKeepingFile)) {
    recordKeeping <-  readr::read_csv(recordKeepingFile, col_types = readr::cols())
    idx <- getKeyIndex(list(...), recordKeeping)
    if (length(idx) > 0) {
      recordKeeping <- recordKeeping[-idx, ]
    }
  } else {
    recordKeeping <- tibble::tibble()
  }
  newRow <- tibble::as_tibble(list(...))
  newRow$checksum <- checksum
  newRow$timeStamp <-  Sys.time()
  recordKeeping <- dplyr::bind_rows(recordKeeping, newRow)
  readr::write_csv(recordKeeping, recordKeepingFile)
}

saveIncremental <- function(data, fileName, ...) {
  if (length(list(...)[[1]]) == 0) {
    return()
  }
  if (file.exists(fileName)) {
    previousData <- readr::read_csv(fileName, col_types = readr::cols())
    idx <- getKeyIndex(list(...), previousData)
    if (length(idx) > 0) {
      previousData <- previousData[-idx, ] 
    }
    data <- dplyr::bind_rows(previousData, data)
  } 
  readr::write_csv(data, fileName)
}
