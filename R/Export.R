# Copyright 2022 Observational Health Data Sciences and Informatics
#
# This file is part of SelfControlledCaseSeries
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# options(andromedaTempFolder = "d:/andromedaTemp")
# library(dplyr)

#' Create SCCS diagnostics thresholds
#'
#' @description
#' Threshold used when calling [exportToCsv()] to determine if we pass or fail diagnostics.
#'
#' @param mdrrThreshold         What is the maximum allowed minimum detectable relative risk
#'                              (MDRR)?
#' @param easeThreshold         What is the maximum allowed expected absolute systematic error
#'                              (EASE).
#' @param timeTrendPThreshold   What family-wise p-value threshold (alpha) will be used to determine
#'                              temporal instability?
#' @param preExposurePThreshold What p-value threshold (alpha) will be used to determine whether the
#'                              rate of the outcome was higher just before exposure initiation?
#'
#' @return
#' An object of type `SccsDiagnosticThresholds`.
#'
#' @export
createSccsDiagnosticThresholds <- function(mdrrThreshold = 10,
                                           easeThreshold = 0.25,
                                           timeTrendPThreshold = 0.05,
                                           preExposurePThreshold = 0.05) {
  thresholds <- list()
  for (name in names(formals(createSccsDiagnosticThresholds))) {
    thresholds[[name]] <- get(name)
  }
  class(thresholds) <- "SccsDiagnosticThresholds"
  return(thresholds)
}

#' Export SCCSresults to CSV files
#'
#' @details
#' This requires that [runSccsAnalyses()] has been executed first. It exports
#' all the results in the `outputFolder` to CSV files for sharing with other
#' sites.
#'
#' @param outputFolder  The folder where runCmAnalyses() generated all results.
#' @param exportFolder  The folder where the CSV files will written.
#' @param databaseId    A unique ID for the database. This will be appended to
#'                      most tables.
#' @param minCellCount  To preserve privacy: the minimum number of subjects contributing
#'                      to a count before it can be included in the results. If the
#'                      count is below this threshold, it will be set to `-minCellCount`.
#' @param sccsDiagnosticThresholds An object of type `SccsDiagnosticThresholds` as created using
#'                                 [createSccsDiagnosticThresholds()].
#'
#' @return
#' Does not return anything. Is called for the side-effect of populating the `exportFolder`
#' with CSV files.
#'
#' @export
exportToCsv <- function(outputFolder,
                        exportFolder = file.path(outputFolder, "export"),
                        databaseId = 1,
                        minCellCount = 5,
                        sccsDiagnosticThresholds = createSccsDiagnosticThresholds()) {
  errorMessages <- checkmate::makeAssertCollection()
  checkmate::assertCharacter(outputFolder, len = 1, add = errorMessages)
  checkmate::assertDirectoryExists(outputFolder, add = errorMessages)
  checkmate::assertFileExists(file.path(outputFolder, "sccsAnalysisList.rds"), add = errorMessages)
  checkmate::assertFileExists(file.path(outputFolder, "exposuresOutcomeList.rds"), add = errorMessages)
  checkmate::assertFileExists(file.path(outputFolder, "resultsSummary.rds"), add = errorMessages)
  checkmate::assertCharacter(exportFolder, len = 1, add = errorMessages)
  checkmate::assertInt(minCellCount, lower = 0, add = errorMessages)
  checkmate::assertClass(sccsDiagnosticThresholds, "SccsDiagnosticThresholds", add = errorMessages)
  checkmate::reportAssertions(collection = errorMessages)

  if (!file.exists(exportFolder)) {
    dir.create(exportFolder, recursive = TRUE)
  }
  start <- Sys.time()
  message("Exporting results to CSV")
  exportSccsAnalyses(
    outputFolder = outputFolder,
    exportFolder = exportFolder
  )

  exportExposuresOutcomes(
    outputFolder = outputFolder,
    exportFolder = exportFolder
  )

  exportFromSccsDataStudyPopSccsModel(
    outputFolder = outputFolder,
    exportFolder = exportFolder,
    databaseId = databaseId,
    minCellCount = minCellCount,
    sccsDiagnosticThresholds = sccsDiagnosticThresholds
  )

  exportSccsResults(
    outputFolder = outputFolder,
    exportFolder = exportFolder,
    databaseId = databaseId,
    minCellCount = minCellCount
  )

  # Add all to zip file -------------------------------------------------------------------------------
  message("Adding results to zip file")
  zipName <- file.path(exportFolder, sprintf("Results_%s.zip", databaseId))
  files <- list.files(exportFolder, pattern = ".*\\.csv$")
  oldWd <- setwd(exportFolder)
  on.exit(setwd(oldWd))
  DatabaseConnector::createZipFile(zipFile = zipName, files = files)

  delta <- Sys.time() - start
  message("Exporting to CSV took ", signif(delta, 3), " ", attr(delta, "units"))
  message("Results are ready for sharing at:", zipName)
}

writeToCsv <- function(data, fileName, append = FALSE) {
  if (nrow(data) == 0) {
    tableName <- gsub(".csv", "", basename(fileName))
    data <- createEmptyResult(tableName)
  }
  colnames(data) <- SqlRender::camelCaseToSnakeCase(colnames(data))
  readr::write_csv(x = data, file = fileName, append = append)
}

enforceMinCellValue <- function(data, fieldName, minValues, silent = FALSE) {
  toCensor <- !is.na(pull(data, fieldName)) & pull(data, fieldName) < minValues & pull(data, fieldName) != 0
  if (!silent) {
    percent <- round(100 * sum(toCensor) / nrow(data), 1)
    message(
      "    censoring ",
      sum(toCensor),
      " values (",
      percent,
      "%) from ",
      fieldName,
      " because value below minimum"
    )
  }
  if (length(minValues) == 1) {
    data[toCensor, fieldName] <- -minValues
  } else {
    data[toCensor, fieldName] <- -minValues[toCensor]
  }
  return(data)
}

createEmptyResult <- function(tableName) {
  columns <- readr::read_csv(
    file = system.file("csv", "resultsDataModelSpecification.csv", package = "SelfControlledCaseSeries"),
    show_col_types = FALSE
  ) %>%
    SqlRender::snakeCaseToCamelCaseNames() %>%
    filter(.data$tableName == !!tableName) %>%
    pull(.data$columnName) %>%
    SqlRender::snakeCaseToCamelCase()
  result <- vector(length = length(columns))
  names(result) <- columns
  result <- as_tibble(t(result), name_repair = "check_unique")
  result <- result[FALSE, ]
  return(result)
}

exportSccsAnalyses <- function(outputFolder, exportFolder) {
  sccsAnalysisListFile <- file.path(outputFolder, "sccsAnalysisList.rds")
  sccsAnalysisList <- readRDS(sccsAnalysisListFile)

  message("- sccs_analysis table")
  tempFileName <- tempfile()
  sccsAnalysisToRow <- function(sccsAnalysis) {
    ParallelLogger::saveSettingsToJson(sccsAnalysis, tempFileName)
    row <- tibble(
      analysisId = sccsAnalysis$analysisId,
      description = sccsAnalysis$description,
      definition = readChar(tempFileName, file.info(tempFileName)$size)
    )
    return(row)
  }
  sccsAnalysis <- lapply(sccsAnalysisList, sccsAnalysisToRow)
  sccsAnalysis <- bind_rows(sccsAnalysis) %>%
    distinct()
  unlink(tempFileName)
  fileName <- file.path(exportFolder, "sccs_analysis.csv")
  writeToCsv(sccsAnalysis, fileName)

  message("- sccs_covariate_analysis table")
  # sccsAnalysis <- sccsAnalysisList[[1]]
  # i = 1
  sccsAnalysisToRows <- function(sccsAnalysis) {
    if (is.list(sccsAnalysis$createIntervalDataArgs$eraCovariateSettings) && !is(sccsAnalysis$createIntervalDataArgs$eraCovariateSettings, "EraCovariateSettings")) {
      eraCovariateSettingsList <- sccsAnalysis$createIntervalDataArgs$eraCovariateSettings
    } else {
      eraCovariateSettingsList <- list(sccsAnalysis$createIntervalDataArgs$eraCovariateSettings)
    }
    rows <- list()
    for (i in seq_along(eraCovariateSettingsList)) {
      eraCovariateSettings <- eraCovariateSettingsList[[i]]
      row <- tibble(
        analysisId = sccsAnalysis$analysisId,
        covariateAnalysisId = i,
        covariateAnalysisName = eraCovariateSettings$label,
        variableOfInterest = ifelse(eraCovariateSettings$exposureOfInterest, 1, 0)
      )
      rows[[length(rows) + 1]] <- row
    }
    return(bind_rows(rows))
  }
  sccsCovariateAnalysis <- lapply(sccsAnalysisList, sccsAnalysisToRows)
  sccsCovariateAnalysis <- sccsCovariateAnalysis %>%
    bind_rows()
  fileName <- file.path(exportFolder, "sccs_covariate_analysis.csv")
  writeToCsv(sccsCovariateAnalysis, fileName)
}

exportExposuresOutcomes <- function(outputFolder, exportFolder) {
  message("- sccs_exposure and sccs_exposures_outcome_set tables")

  esoList <- readRDS(file.path(outputFolder, "exposuresOutcomeList.rds"))

  # exposure = eso$exposures[[1]]
  convertExposureToTable <- function(exposure) {
    tibble(
      eraId = exposure$exposureId,
      trueEffectSize = if (is.null(exposure$trueEffectSize)) as.numeric(NA) else exposure$trueEffectSize
    ) %>%
      return()
  }
  sccsExposure <- list()
  sccsExposuresOutcomeSet <- list()

  # i = 1
  for (i in seq_along(esoList)) {
    eso <- esoList[[i]]
    exposures <- lapply(eso$exposures, convertExposureToTable) %>%
      bind_rows() %>%
      mutate(
        exposuresOutcomeSetId = i
      )
    sccsExposure[[length(sccsExposure) + 1]] <- exposures

    exposuresOutcomeSet <- tibble(
      exposuresOutcomeSetId = i,
      outcomeId = eso$outcomeId
    )
    sccsExposuresOutcomeSet[[length(sccsExposuresOutcomeSet) + 1]] <- exposuresOutcomeSet
  }

  sccsExposure <- sccsExposure %>%
    bind_rows()
  fileName <- file.path(exportFolder, "sccs_exposure.csv")
  writeToCsv(sccsExposure, fileName)

  sccsExposuresOutcomeSet <- sccsExposuresOutcomeSet %>%
    bind_rows()
  fileName <- file.path(exportFolder, "sccs_exposures_outcome_set.csv")
  writeToCsv(sccsExposuresOutcomeSet, fileName)
}

exportFromSccsDataStudyPopSccsModel <- function(outputFolder, exportFolder, databaseId, minCellCount, sccsDiagnosticThresholds) {
  message("- sccs_age_spanning, sccs_attrition, sccs_calender_time_spanning, sccs_censor_model, sccs_covariate, sccs_covariate_result, sccs_diagnostics_summary, sccs_era, sccs_event_dep_observation, sccs_likelihood_profile, sccs_spline, sccs_time_to_event, and sccs_time_trend tables")
  reference <- getFileReference(outputFolder) %>%
    arrange(.data$sccsDataFile, .data$studyPopFile, .data$sccsModelFile)
  esoList <- readRDS(file.path(outputFolder, "exposuresOutcomeList.rds"))
  ease <- getResultsSummary(outputFolder) %>%
    distinct(.data$exposuresOutcomeSetId, .data$analysisId, .data$eraId, .data$covariateId, .data$ease)

  sccsAgeSpanning <- list()
  sccsAttrition <- list()
  sccsCalendarTimeSpanning <- list()
  sccsCensorModel <- list()
  sccsCovariate <- list()
  sccsCovariateResult <- list()
  sccsEra <- list()
  sccsEventDepObservation <- list()
  sccsLikelihoodProfile <- list()
  sccsSpline <- list()
  sccsTimeToEvent <- list()
  sccsTimeTrend <- list()
  sccsDiagnosticsSummary <- list()

  sccsDataFile <- ""
  studyPopFile <- ""

  pb <- txtProgressBar(style = 3)
  # i <- 75
  for (i in seq_len(nrow(reference))) {
    refRow <- reference[i, ]
    if (refRow$sccsDataFile != sccsDataFile) {
      sccsDataFile <- refRow$sccsDataFile
      sccsData <- loadSccsData(file.path(outputFolder, sccsDataFile))

      # sccsEra table
      eraRef <- sccsData$eraRef %>%
        collect()
      rows <- reference %>%
        filter(.data$sccsDataFile == !!sccsDataFile) %>%
        select("exposuresOutcomeSetId", "analysisId") %>%
        inner_join(eraRef, by = character()) %>%
        mutate(databaseId = !!databaseId)
      sccsEra[[length(sccsEra) + 1]] <- rows
    }
    if (refRow$studyPopFile != studyPopFile) {
      studyPopFile <- refRow$studyPopFile
      studyPop <- readRDS(file.path(outputFolder, studyPopFile))

      # sccs_age_spanning table
      ageSpans <- computeSpans(studyPop, variable = "age") %>%
        mutate(databaseId = !!databaseId)
      refRows <- reference %>%
        filter(.data$studyPopFile == !!studyPopFile)
      sccsAgeSpanning[[length(sccsAgeSpanning) + 1]] <- refRows %>%
        select("analysisId", "exposuresOutcomeSetId") %>%
        inner_join(ageSpans, by = character())

      # sccs_calendar_time_spanning table
      timeSpans <- computeSpans(studyPop, variable = "time") %>%
        mutate(databaseId = !!databaseId)
      refRows <- reference %>%
        filter(.data$studyPopFile == !!studyPopFile)
      sccsCalendarTimeSpanning[[length(sccsCalendarTimeSpanning) + 1]] <- refRows %>%
        select("analysisId", "exposuresOutcomeSetId") %>%
        inner_join(timeSpans, by = character())

      # sccsEventDepObservation table
      data <- computeTimeToObsEnd(studyPop) %>%
        mutate(monthsToEnd = round(.data$daysFromEvent / 30.5)) %>%
        group_by(.data$monthsToEnd, .data$censoring) %>%
        summarize(outcomes = n(), .groups = "drop") %>%
        mutate(censored = ifelse(.data$censoring == "Censored", 1, 0)) %>%
        select("monthsToEnd", "censored", "outcomes") %>%
        mutate(databaseId = !!databaseId)
      refRows <- reference %>%
        filter(.data$studyPopFile == !!studyPopFile)
      sccsEventDepObservation[[length(sccsEventDepObservation) + 1]] <- refRows %>%
        select("analysisId", "exposuresOutcomeSetId") %>%
        inner_join(data, by = character())
    }
    sccsModel <- readRDS(file.path(outputFolder, as.character(refRow$sccsModelFile)))
    if (is.null(sccsModel$estimates)) {
      estimates <- tibble(covariateId = 1, rr = 1, ci95Lb = 1, ci95Ub = 1) %>%
        filter(.data$covariateId == 2)
    } else {
      estimates <- sccsModel$estimates %>%
        mutate(rr = exp(.data$logRr), ci95Lb = exp(.data$logLb95), ci95Ub = exp(.data$logUb95))
    }

    # sccsTimeToEvent table
    for (exposure in esoList[[refRow$exposuresOutcomeSetId]]$exposures) {
      data <- computeTimeToEvent(
        studyPopulation = studyPop,
        sccsData = sccsData,
        exposureEraId = exposure$exposureId
      ) %>%
        mutate(
          databaseId = !!databaseId,
          eraId = exposure$exposureId,
          outcomes = .data$eventsExposed + .data$eventsUnexposed
        ) %>%
        select("databaseId",
          "eraId",
          week = "number",
          "outcomes",
          observedSubjects = "observed"
        )

      sccsTimeToEvent[[length(sccsTimeToEvent) + 1]] <- refRow %>%
        select("analysisId", "exposuresOutcomeSetId") %>%
        bind_cols(data)
    }

    # sccsAttrition table
    baseAttrition <- refRow %>%
      select("analysisId", "exposuresOutcomeSetId") %>%
      bind_cols(
        sccsModel$metaData$attrition %>%
          rename(outcomeObservationPeriods = "outcomeObsPeriods") %>%
          mutate(sequenceNumber = row_number()) %>%
          select(-"outcomeId")
      ) %>%
      mutate(databaseId = !!databaseId)
    # covariateSettings = sccsModel$metaData$covariateSettingsList[[1]]
    for (covariateSettings in sccsModel$metaData$covariateSettingsList) {
      if (covariateSettings$exposureOfInterest) {
        if (is.null(sccsModel$metaData$covariateStatistics)) {
          covariateStatistics <- tibble(
            covariateId = covariateSettings$outputIds[1],
            personCount = 0,
            eraCount = 0,
            dayCount = 0,
            outcomeCount = 0,
            observationPeriodCount = 0,
            observedDayCount = 0,
            observedOutcomeCount = 0
          )
        } else {
          covariateStatistics <- sccsModel$metaData$covariateStatistics
        }
        attrition <- bind_rows(
          baseAttrition,
          covariateStatistics %>%
            filter(.data$covariateId == covariateSettings$outputIds[1]) %>%
            mutate(
              analysisId = refRow$analysisId,
              exposuresOutcomeSetId = refRow$exposuresOutcomeSetId,
              description = "Having the covariate of interest",
              sequenceNumber = max(baseAttrition$sequenceNumber) + 1,
              databaseId = !!databaseId
            ) %>%
            select(
              "analysisId",
              "exposuresOutcomeSetId",
              "description",
              outcomeSubjects = "personCount",
              outcomeEvents = "observedOutcomeCount",
              outcomeObservationPeriods = "observationPeriodCount",
              observedDays = "observedDayCount",
              "sequenceNumber",
              "databaseId"
            )
        ) %>%
          mutate(covariateId = covariateSettings$outputIds[1])
        sccsAttrition[[length(sccsAttrition) + 1]] <- attrition
      }
    }

    # sccsCovariate table
    sccsCovariate[[length(sccsCovariate) + 1]] <- refRow %>%
      select("analysisId", "exposuresOutcomeSetId") %>%
      bind_cols(
        sccsModel$metaData$covariateRef %>%
          select("covariateAnalysisId", "covariateId", "covariateName", eraId = "originalEraId")
      ) %>%
      mutate(databaseId = !!databaseId)

    # sccsCovariateResult table
    sccsCovariateResult[[length(sccsCovariateResult) + 1]] <- refRow %>%
      select("analysisId", "exposuresOutcomeSetId") %>%
      bind_cols(
        sccsModel$metaData$covariateRef %>%
          select("covariateId") %>%
          left_join(
            estimates %>%
              select("covariateId", "rr", "ci95Lb", "ci95Ub"),
            by = "covariateId"
          )
      ) %>%
      mutate(databaseId = !!databaseId)

    # sccsLikelihoodProfile table
    for (j in seq_along(sccsModel$logLikelihoodProfiles)) {
      if (!is.null(sccsModel$logLikelihoodProfiles[[j]])) {
        sccsLikelihoodProfile[[length(sccsLikelihoodProfile) + 1]] <- refRow %>%
          select("analysisId", "exposuresOutcomeSetId") %>%
          bind_cols(
            sccsModel$logLikelihoodProfiles[[j]] %>%
              rename(logRr = "point", logLikelihood = "value") %>%
              mutate(covariateId = as.numeric(names(sccsModel$logLikelihoodProfiles[j])))
          ) %>%
          mutate(databaseId = !!databaseId)
      }
    }

    # sccsSpline table
    if (!is.null(sccsModel$metaData$age)) {
      ageKnots <- sccsModel$metaData$age$ageKnots

      sccsSpline[[length(sccsSpline) + 1]] <- refRow %>%
        select("analysisId", "exposuresOutcomeSetId") %>%
        bind_cols(
          tibble(
            covariateId = 99 + seq_len(length(ageKnots)),
            knotMonth = ageKnots
          ) %>%
            left_join(
              estimates %>%
                filter(.data$covariateId >= 99 & .data$covariateId < 200) %>%
                select("covariateId", "rr"),
              by = "covariateId"
            ) %>%
            select("knotMonth", "rr")
        ) %>%
        mutate(
          databaseId = !!databaseId,
          splineType = "age"
        )
    }
    if (!is.null(sccsModel$metaData$seasonality)) {
      seasonKnots <- sccsModel$metaData$seasonality$seasonKnots
      seasonKnots <- seasonKnots[c(-1, -length(seasonKnots))]

      sccsSpline[[length(sccsSpline) + 1]] <- refRow %>%
        select("analysisId", "exposuresOutcomeSetId") %>%
        bind_cols(
          tibble(
            covariateId = 199 + seq_len(length(seasonKnots)),
            knotMonth = seasonKnots
          ) %>%
            left_join(
              estimates %>%
                filter(.data$covariateId >= 200 & .data$covariateId < 300) %>%
                select("covariateId", "rr"),
              by = "covariateId"
            ) %>%
            select("knotMonth", "rr") %>%
            bind_rows(tibble(knotMonth = 1, rr = 1))
        ) %>%
        mutate(
          databaseId = !!databaseId,
          splineType = "season"
        )
    }
    if (!is.null(sccsModel$metaData$calendarTime)) {
      calendarTimeKnots <- sccsModel$metaData$calendarTime$calendarTimeKnots

      sccsSpline[[length(sccsSpline) + 1]] <- refRow %>%
        select("analysisId", "exposuresOutcomeSetId") %>%
        bind_cols(
          tibble(
            covariateId = 299 + seq_len(length(calendarTimeKnots)),
            knotMonth = calendarTimeKnots
          ) %>%
            left_join(
              estimates %>%
                filter(.data$covariateId >= 299 & .data$covariateId < 400) %>%
                select("covariateId", "rr"),
              by = "covariateId"
            ) %>%
            select("knotMonth", "rr")
        ) %>%
        mutate(
          databaseId = !!databaseId,
          splineType = "calendar time"
        )
    }

    # sccsCensorModel table
    if (!is.null(sccsModel$metaData$censorModel)) {
      censorModel <- sccsModel$metaData$censorModel
      sccsCensorModel[[length(sccsCensorModel) + 1]] <- refRow %>%
        select("analysisId", "exposuresOutcomeSetId") %>%
        bind_cols(
          tibble(
            parameterId = seq_len(length(censorModel$p)),
            parameterValue = censorModel$p,
            modelType = case_when(
              censorModel$model == 1 ~ "Weibull-Age",
              censorModel$model == 2 ~ "Weibull-Interval",
              censorModel$model == 3 ~ "Gamma-Age",
              censorModel$model == 4 ~ "Gamma-Interval"
            ),
            databaseId = !!databaseId
          )
        )
    }

    # sccsTimeTrend table
    timeTrendData <- computeTimeStability(
      studyPopulation = studyPop,
      sccsModel = sccsModel
    ) %>%
      mutate(
        calendarYear = floor(.data$month / 12),
        calendarMonth = floor(.data$month %% 12) + 1,
        stable = as.integer(.data$stable)
      ) %>%
      select(
        "calendarYear",
        "calendarMonth",
        observedSubjects = "observationPeriodCount",
        outcomeRate = "rate",
        "adjustedRate",
        "stable",
        "p"
      ) %>%
      mutate(databaseId = !!databaseId)
    timeTrendData <- enforceMinCellValue(timeTrendData, "outcomeRate", minCellCount / timeTrendData$observedSubjects, silent = TRUE)
    timeTrendData <- enforceMinCellValue(timeTrendData, "adjustedRate", minCellCount / timeTrendData$observedSubjects, silent = TRUE)

    sccsTimeTrend[[length(sccsTimeTrend) + 1]] <- refRow %>%
      select("analysisId", "exposuresOutcomeSetId") %>%
      bind_cols(timeTrendData)

    # sccsDiagnosticsSummary table
    table <- ease %>%
      filter(.data$exposuresOutcomeSetId == refRow$exposuresOutcomeSetId & .data$analysisId == refRow$analysisId) %>%
      mutate(
        mdrr = as.numeric(NA),
        timeTrendP = min(timeTrendData$p * nrow(timeTrendData)),
        preExposureP = as.numeric(NA)
      )
    for (j in seq_len(nrow(table))) {
      mdrr <- computeMdrr(object = sccsModel, exposureCovariateId = table$covariateId[j])
      table$mdrr[j] <- mdrr$mdrr
      preExposureP <- computePreExposureGainP(
        sccsData = sccsData,
        studyPopulation = studyPop,
        exposureEraId = table$eraId[j]
      )
      table$preExposureP[j] <- preExposureP
    }
    table <- table %>%
      mutate(
        databaseId = !!databaseId,
        easeDiagnostic = case_when(
          is.na(.data$ease) ~ "NOT EVALUATED",
          .data$ease <= sccsDiagnosticThresholds$easeThreshold ~ "PASS",
          TRUE ~ "FAIL"
        ),
        mdrrDiagnostic = case_when(
          is.na(.data$mdrr) ~ "NOT EVALUATED",
          .data$mdrr <= sccsDiagnosticThresholds$mdrrThreshold ~ "PASS",
          TRUE ~ "FAIL"
        ),
        timeTrendDiagnostic = case_when(
          is.na(.data$timeTrendP) ~ "NOT EVALUATED",
          .data$timeTrendP >= sccsDiagnosticThresholds$timeTrendPThreshold ~ "PASS",
          TRUE ~ "FAIL"
        ),
        preExposureDiagnostic = case_when(
          is.na(.data$preExposureP) ~ "NOT EVALUATED",
          .data$preExposureP >= sccsDiagnosticThresholds$preExposurePThreshold ~ "PASS",
          TRUE ~ "FAIL"
        )
      ) %>%
      mutate(unblind = ifelse(.data$easeDiagnostic == "PASS" & .data$mdrrDiagnostic == "PASS" & .data$timeTrendDiagnostic == "PASS" & .data$preExposureDiagnostic == "PASS", 1, 0)) %>%
      select(-"eraId")
    sccsDiagnosticsSummary[[length(sccsDiagnosticsSummary) + 1]] <- table

    setTxtProgressBar(pb, i / nrow(reference))
  }
  close(pb)

  message("  Censoring sccs_age_spanning table")
  sccsAgeSpanning <- sccsAgeSpanning %>%
    bind_rows() %>%
    enforceMinCellValue("coverBeforeAfterSubjects", minCellCount)
  fileName <- file.path(exportFolder, "sccs_age_spanning.csv")
  writeToCsv(sccsAgeSpanning, fileName)

  sccsEra <- sccsEra %>%
    bind_rows()
  fileName <- file.path(exportFolder, "sccs_era.csv")
  writeToCsv(sccsEra, fileName)

  message("  Censoring sccs_attrition table")
  sccsAttrition <- sccsAttrition %>%
    bind_rows() %>%
    enforceMinCellValue("outcomeSubjects", minCellCount) %>%
    enforceMinCellValue("outcomeEvents", minCellCount) %>%
    enforceMinCellValue("outcomeObservationPeriods", minCellCount) %>%
    enforceMinCellValue("observedDays", minCellCount)
  fileName <- file.path(exportFolder, "sccs_attrition.csv")
  writeToCsv(sccsAttrition, fileName)

  message("  Censoring sccs_age_spanning table")
  sccsCalendarTimeSpanning <- sccsCalendarTimeSpanning %>%
    bind_rows() %>%
    enforceMinCellValue("coverBeforeAfterSubjects", minCellCount)
  fileName <- file.path(exportFolder, "sccs_calendar_time_spanning.csv")
  writeToCsv(sccsCalendarTimeSpanning, fileName)

  sccsCovariate <- sccsCovariate %>%
    bind_rows() %>%
    distinct()
  fileName <- file.path(exportFolder, "sccs_covariate.csv")
  writeToCsv(sccsCovariate, fileName)

  sccsCovariateResult <- sccsCovariateResult %>%
    bind_rows()
  fileName <- file.path(exportFolder, "sccs_covariate_result.csv")
  writeToCsv(sccsCovariateResult, fileName)

  sccsDiagnosticsSummary <- sccsDiagnosticsSummary %>%
    bind_rows()
  fileName <- file.path(exportFolder, "sccs_diagnostics_summary.csv")
  writeToCsv(sccsDiagnosticsSummary, fileName)

  message("  Censoring sccs_event_dep_observation table")
  sccsEventDepObservation <- sccsEventDepObservation %>%
    bind_rows() %>%
    enforceMinCellValue("outcomes", minCellCount)
  fileName <- file.path(exportFolder, "sccs_event_dep_observation.csv")
  writeToCsv(sccsEventDepObservation, fileName)

  sccsLikelihoodProfile <- sccsLikelihoodProfile %>%
    bind_rows()
  fileName <- file.path(exportFolder, "sccs_likelihood_profile.csv")
  writeToCsv(sccsLikelihoodProfile, fileName)

  sccsSpline <- sccsSpline %>%
    bind_rows()
  fileName <- file.path(exportFolder, "sccs_spline.csv")
  writeToCsv(sccsSpline, fileName)

  sccsCensorModel <- sccsCensorModel %>%
    bind_rows()
  fileName <- file.path(exportFolder, "sccs_censor_model.csv")
  writeToCsv(sccsCensorModel, fileName)

  message("  Censoring sccs_time_to_event table")
  sccsTimeToEvent <- sccsTimeToEvent %>%
    bind_rows() %>%
    enforceMinCellValue("outcomes", minCellCount) %>%
    enforceMinCellValue("observedSubjects", minCellCount)
  fileName <- file.path(exportFolder, "sccs_time_to_event.csv")
  writeToCsv(sccsTimeToEvent, fileName)

  message(" Censoring sccs_time_trend table")
  sccsTimeTrend <- sccsTimeTrend %>%
    bind_rows() %>%
    enforceMinCellValue("observedSubjects", minCellCount)
  fileName <- file.path(exportFolder, "sccs_time_trend.csv")
  writeToCsv(sccsTimeTrend, fileName)
}

computeSpans <- function(studyPopulation, variable = "age") {
  if (variable == "age") {
    ages <- studyPopulation$cases %>%
      transmute(
        start = ceiling(.data$ageInDays / (365.25 / 4)) + 1,
        end = floor((.data$ageInDays + .data$endDay) / (365.25 / 4)) - 1,
        count = 1
      )
  } else {
    ages <- studyPopulation$cases %>%
      transmute(
        start = convertDateToMonth(.data$startDate) + 1,
        end = convertDateToMonth(.data$startDate + .data$endDay) - 1,
        count = 1
      )
  }

  addedCounts <- ages %>%
    rename(month = "start") %>%
    group_by(.data$month) %>%
    summarise(addedCount = sum(.data$count), .groups = "drop")
  removedCounts <- ages %>%
    rename(month = "end") %>%
    group_by(.data$month) %>%
    summarise(removedCount = sum(.data$count), .groups = "drop")
  counts <- addedCounts %>%
    full_join(removedCounts, by = "month") %>%
    mutate(
      addedCount = if_else(is.na(.data$addedCount), 0, .data$addedCount),
      removedCount = if_else(is.na(.data$removedCount), 0, .data$removedCount)
    ) %>%
    mutate(netAdded = .data$addedCount - .data$removedCount) %>%
    arrange(.data$month) %>%
    mutate(count = cumsum(.data$netAdded)) %>%
    filter(count > 0) %>%
    select("month", "count")
  if (nrow(counts) != 0) {
    counts <- counts %>%
      full_join(
        tibble(month = seq(min(counts$month), max(counts$month))),
        by = "month"
      ) %>%
      arrange(.data$month)
  }
  lastCount <- 0
  for (i in seq_len(nrow(counts))) {
    if (is.na(counts$count[i])) {
      counts$count[i] <- lastCount
    } else {
      lastCount <- counts$count[i]
    }
  }
  if (variable == "age") {
    counts <- counts %>%
      rename(ageMonth = "month", coverBeforeAfterSubjects = "count")
  } else {
    counts <- counts %>%
      transmute(
        calendarYear = floor(.data$month / 12),
        calendarMonth = .data$month %% 12 + 1,
        coverBeforeAfterSubjects = .data$count
      )
  }

  return(counts)
}

exportSccsResults <- function(outputFolder,
                              exportFolder,
                              databaseId,
                              minCellCount) {
  message("- sccs_result table")
  results <- getResultsSummary(outputFolder) %>%
    select(
      "analysisId",
      "exposuresOutcomeSetId",
      "covariateId",
      "rr",
      "ci95Lb",
      "ci95Ub",
      "p",
      "outcomeSubjects",
      "outcomeEvents",
      "outcomeObservationPeriods",
      "covariateSubjects",
      "covariateDays",
      "covariateEras",
      "covariateOutcomes",
      "observedDays",
      "logRr",
      "seLogRr",
      "llr",
      "calibratedRr",
      "calibratedCi95Lb",
      "calibratedCi95Ub",
      "calibratedP",
      "calibratedLogRr",
      "calibratedSeLogRr"
    ) %>%
    mutate(databaseId = !!databaseId) %>%
    enforceMinCellValue("outcomeSubjects", minCellCount) %>%
    enforceMinCellValue("outcomeEvents", minCellCount) %>%
    enforceMinCellValue("outcomeObservationPeriods", minCellCount) %>%
    enforceMinCellValue("covariateSubjects", minCellCount) %>%
    enforceMinCellValue("covariateDays", minCellCount) %>%
    enforceMinCellValue("covariateEras", minCellCount) %>%
    enforceMinCellValue("covariateOutcomes", minCellCount) %>%
    enforceMinCellValue("observedDays", minCellCount)
  fileName <- file.path(exportFolder, "sccs_result.csv")
  writeToCsv(results, fileName)
}
