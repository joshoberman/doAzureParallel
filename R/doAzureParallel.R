#' The registerDoAzureParallel function is used to register the Azure cloud-enabled parallel backend with the foreach package.
#'
#' @param cluster The cluster object to use for parallelization
#'
#' @examples
#' registerDoAzureParallel(cluster)
#' @export
registerDoAzureParallel <- function(cluster){
  setDoPar(fun = .doAzureParallel, data = list(config = list(cluster$batchAccount, cluster$storageAccount), poolId = cluster$poolId), info = .info)
}

.info <- function(data, item){
  switch(item,
         workers = workers(data),
         name = "doAzureParallel",
         version = packageDescription("doAzureParallel", fields = "Version"),
         NULL)
}

.makeDotsEnv <- function(...){
  list(...)
  function() NULL
}

workers <- function(data){
  id <- data$poolId
  pool <- getPool(id)

  if(getOption("verbose")){
    getPoolWorkers(id)
  }

  (pool$currentDedicatedNodes * pool$maxTasksPerNode) + (pool$currentLowPriorityNodes * pool$maxTasksPerNode)
}

.isError <- function(x){
  ifelse(inherits(x, "simpleError") || inherits(x, "try-error"), 1, 0)
}

.getSimpleErrorMessage <- function(e) {
  print(e$message)
  e$message
}
.getSimpleErrorCall <- function(e) deparse(e$call)

#' Groups iterations of the foreach loop together per task.
#'
#' @param value The number of iterations to group
#'
#' @examples
#' setChunkSize(10)
#' @export
setChunkSize <- function(value = 1){
  if(!is.numeric(value)) stop("setChunkSize requires a numeric argument")

  value <- max(round(value), 1)

  assign("chunkSize", value, envir=.doAzureBatchGlobals)
}

#' Set the verbosity for calling httr rest api calls
#'
#' @param value Boolean value for turning on and off verbose mode
#'
#' @examples
#' setVerbose(TRUE)
#' @export
setVerbose <- function(value = FALSE){
  if(!is.logical(value)) stop("setVerbose requires a logical argument")

  options(verbose = value)
}

.doAzureParallel <- function(obj, expr, envir, data){
  stopifnot(inherits(obj, "foreach"))

  batchCredentials <- getBatchCredentials()
  storageCredentials <- getStorageCredentials()

  it <- iter(obj)
  argsList <- as.list(it)

  chunkSize <- 1
  #this is hardcoded to 1 hr, preference would be to scale with size of job
  jobTimeout <- 60 * 60 * 1

  if(!is.null(obj$options$azure$timeout)){
    jobTimeout <- obj$options$azure$timeout
  }

  exportenv <- tryCatch({
    qargs <- quote(list(...))
    args <- eval(qargs, envir)
    environment(do.call(.makeDotsEnv, args))
  },
  error=function(e) {
    new.env(parent=emptyenv())
  })
  noexport <- union(obj$noexport, obj$argnames)
  getexports(expr, exportenv, envir, bad = noexport)
  vars <- ls(exportenv)

  export <- unique(obj$export)
  ignore <- intersect(export, vars)
  if(length(ignore) > 0){
    export <- setdiff(export, ignore)
  }

  # add explicitly exported variables to exportenv
  if (length(export) > 0) {
    if (obj$verbose)
      cat(sprintf('explicitly exporting variables(s): %s\n',
                  paste(export, collapse=', ')))

    for (sym in export) {
      if (!exists(sym, envir, inherits=TRUE))
        stop(sprintf('unable to find variable "%s"', sym))
      val <- get(sym, envir, inherits=TRUE)
      if (is.function(val) &&
          (identical(environment(val), .GlobalEnv) ||
           identical(environment(val), envir))) {
        # Changing this function's environment to exportenv allows it to
        # access/execute any other functions defined in exportenv.  This
        # has always been done for auto-exported functions, and not
        # doing so for explicitly exported functions results in
        # functions defined in exportenv that can't call each other.
        environment(val) <- exportenv
      }
      assign(sym, val, pos=exportenv, inherits=FALSE)
    }
  }

  pkgName <- if (exists('packageName', mode='function'))
    packageName(envir)
  else
    NULL

  assign('expr', expr, .doAzureBatchGlobals)
  assign('exportenv', exportenv, .doAzureBatchGlobals)
  assign('packages', obj$packages, .doAzureBatchGlobals)
  assign('pkgName', pkgName, .doAzureBatchGlobals)

  time <- format(Sys.time(), "%Y%m%d%H%M%S", tz = "GMT")
  id <-  sprintf("%s%s",
                 "job",
                 time)

  if(!is.null(obj$options$azure$job)){
    id <- obj$options$azure$job
  }

  wait <- TRUE
  if(!is.null(obj$options$azure$wait)){
    wait <- obj$options$azure$wait
  }

  inputs <- FALSE
  if(!is.null(obj$options$azure$inputs)){
    storageCredentials <- getStorageCredentials()
    sasToken <- createSasToken("r", "c", inputs)

    assign("inputs", list(name = storageCredentials$name,
                          sasToken = sasToken),
           .doAzureBatchGlobals)
  }

  retryCounter <- 0
  maxRetryCount <- 5
  startupFolderName <- "startup"
  containerResponse <- NULL
  jobquotaReachedResponse <- NULL
  while(retryCounter < maxRetryCount){
    sprintf("job id is: %s", id)
    # try to submit the job. We may run into naming conflicts. If so, try again
    tryCatch({
      retryCounter <- retryCounter + 1

      response <- createContainer(id, raw = TRUE)
      if(grepl("ContainerAlreadyExists", response)){
        if(!is.null(obj$options$azure$job)){
          containerResponse <- grepl("ContainerAlreadyExists", response)
          break;
        }

        stop("Container already exists. Multiple jobs may possibly be running.")
      }

      uploadBlob(id, system.file(startupFolderName, "worker.R", package="doAzureParallel"))
      uploadBlob(id, system.file(startupFolderName, "merger.R", package="doAzureParallel"))

      # Setting up common job environment for all tasks
      jobFileName <- paste0(id, ".rds")
      saveRDS(.doAzureBatchGlobals, file = jobFileName)
      uploadBlob(id, paste0(getwd(), "/", jobFileName))
      file.remove(jobFileName)

      resourceFiles <- list()
      if(!is.null(obj$options$azure$resourceFiles)){
        resourceFiles <- obj$options$azure$resourceFiles
      }

      if(!is.null(obj$options$azure$resourcefiles)){
        resourceFiles <- obj$options$azure$resourcefiles
      }

      sasToken <- createSasToken("r", "c", id)
      workerScriptUrl <- createBlobUrl(storageCredentials$name, id, "worker.R", sasToken)
      mergerScriptUrl <- createBlobUrl(storageCredentials$name, id, "merger.R", sasToken)
      jobCommonFileUrl <- createBlobUrl(storageCredentials$name, id, jobFileName, sasToken)
      requiredJobResourceFiles <- list(
                            createResourceFile(url = workerScriptUrl, fileName = "worker.R"),
                            createResourceFile(url = mergerScriptUrl, fileName = "merger.R"),
                            createResourceFile(url = jobCommonFileUrl, fileName = jobFileName))

      # We need to merge any files passed by the calling lib with the resource files specified here
      resourceFiles <- append(resourceFiles, requiredJobResourceFiles)

      response <- .addJob(jobId = id,
                          poolId = data$poolId,
                          resourceFiles = resourceFiles,
                          packages = obj$packages)

      if(grepl("ActiveJobAndScheduleQuotaReached", response)){
        jobquotaReachedResponse <- grepl("ActiveJobAndScheduleQuotaReached", response)
      }

      if(grepl("JobExists", response)){
        stop("The specified job already exists.")
      }

      break;
    },
    error=function(e) {
      if (retryCounter == maxRetryCount) {
        cat(sprintf('Error creating job: %s\n',
                  conditionMessage(e)))
      }

      print(e)
      time <- format(Sys.time(), "%Y%m%d%H%M%S", tz = "GMT")
      id <-  sprintf("%s%s",
                    "job",
                    time)
    })
  }

  if(!is.null(containerResponse)){
    stop("Aborted mission. The container has already exist with user's specific job id. Please use a different job id.")
  }

  if(!is.null(jobquotaReachedResponse)){
    stop("Aborted mission. Your active job quota has been reached. To increase your active job quota, go to https://docs.microsoft.com/en-us/azure/batch/batch-quota-limit")
  }

  print("Job Summary: ")
  job <- getJob(id)
  print(sprintf("Id: %s", job$id))

  chunkSize <- 1

  if(!is.null(obj$options$azure$chunkSize)){
    chunkSize <- obj$options$azure$chunkSize
  }

  if(!is.null(obj$options$azure$chunksize)){
    chunkSize <- obj$options$azure$chunksize
  }

  if(exists("chunkSize", envir=.doAzureBatchGlobals)){
    chunkSize <- get("chunkSize", envir=.doAzureBatchGlobals)
  }

  ntasks <- length(argsList)
  nout <- ceiling(ntasks / chunkSize)
  remainingtasks <- ntasks %% chunkSize

  startIndices <- seq(1, length(argsList), chunkSize)

  endIndices <-
    if(chunkSize >= length(argsList))
    {
      c(length(argsList))
    }
    else {
      seq(chunkSize, length(argsList), chunkSize)
    }

  minLength <- min(length(startIndices), length(endIndices))

  if(length(startIndices) > length(endIndices)){
    endIndices[length(startIndices)] <- ntasks
  }

  tasks <- lapply(1:length(endIndices), function(i){
    startIndex <- startIndices[i]
    endIndex <- endIndices[i]
    taskId <- paste0(id, "-task", i)

    .addTask(id,
            taskId = taskId,
            rCommand =  sprintf("Rscript --vanilla --verbose $AZ_BATCH_JOB_PREP_WORKING_DIR/worker.R %s %s %s %s > %s.txt", "$AZ_BATCH_JOB_PREP_WORKING_DIR", "$AZ_BATCH_TASK_WORKING_DIR", jobFileName, paste0(taskId, ".rds"), taskId),
            args = argsList[startIndex:endIndex],
            envir = .doAzureBatchGlobals,
            packages = obj$packages)

    return(taskId)
  })

  updateJob(id)

  r <- .addTask(id,
             taskId = paste0(id, "-merge"),
             rCommand = sprintf("Rscript --vanilla --verbose $AZ_BATCH_JOB_PREP_WORKING_DIR/merger.R %s %s %s %s %s > %s.txt",
                                "$AZ_BATCH_JOB_PREP_WORKING_DIR",
                                "$AZ_BATCH_TASK_WORKING_DIR",
                                id,
                                length(tasks),
                                ntasks,
                                paste0(id, "-merge")),
             envir = .doAzureBatchGlobals,
             packages = obj$packages,
             dependsOn = tasks)

  if(wait){
    waitForTasksToComplete(id, jobTimeout, progress = !is.null(obj$progress), tasks = nout + 1)

    response <- downloadBlob(id, paste0("result/", id, "-merge-result.rds"), sasToken = sasToken, accountName = storageCredentials$name)
    tempFile <- tempfile("doAzureParallel", fileext = ".rds")
    bin <- content(response, "raw")
    writeBin(bin, tempFile)
    results <- readRDS(tempFile)

    failTasks <- sapply(results, .isError)

    numberOfFailedTasks <- sum(unlist(failTasks))

    if(numberOfFailedTasks > 0){
      .createErrorViewerPane(id, failTasks)
    }

    accumulator <- makeAccum(it)

    tryCatch(accumulator(results, seq(along = results)), error = function(e){
      cat('error calling combine function:\n')
      print(e)
    })

    # check for errors
    errorValue <- getErrorValue(it)
    errorIndex <- getErrorIndex(it)

    print(sprintf("Number of errors: %i", numberOfFailedTasks))

    deleteJob(id)
    deleteContainer(id)

    if (identical(obj$errorHandling, 'stop') && !is.null(errorValue)) {
      msg <- sprintf('task %d failed - "%s"', errorIndex,
                     conditionMessage(errorValue))
      stop(simpleError(msg, call=expr))
    }
    else {
      getResult(it)
    }
  }
  else{
    print("Because the 'wait' parameter is set to FALSE, the returned value is the job ID associated with the foreach loop. Use this returned value with getJobResults(job_id) to get the results when the foreach loop is completed in Azure")
    return(id)
  }
}

.createErrorViewerPane <- function(id, failTasks){
  storageCredentials <- getStorageCredentials()

  sasToken <- createSasToken("r", "c", id, storageCredentials$key)

  tempDir <- tempfile()
  dir.create(tempDir)
  htmlFile <- file.path(tempDir, paste0(id, ".html"))

  staticHtml <- "<h1>Errors:</h1>"
  for(i in 1:length(failTasks)){
    if(failTasks[i] == 1){
      stdoutFile <- createBlobUrl(storageCredentials$name, id, "stdout", sasToken)
      stderrFile <- createBlobUrl(storageCredentials$name, id, "stderr", sasToken)
      RstderrFile <- createBlobUrl(storageCredentials$name, id, "logs", sasToken)

      stdoutFile <- paste0(stdoutFile, "/", id, "-task", i, ".txt")
      stderrFile <- paste0(stderrFile, "/", id, "-task", i, ".txt")
      RstderrFile <- paste0(RstderrFile, "/", id, "-task", i, ".txt")

      staticHtml <- paste0(staticHtml, 'Task ', i, ' | <a href="', paste0(stdoutFile, query),'">', "stdout.txt",'</a> |', ' <a href="', paste0(stderrFile, query),'">', "stderr.txt",'</a> | <a href="', paste0(RstderrFile, query),'">', "R output",'</a> <br/>')
    }
  }

  write(staticHtml, htmlFile)

  viewer <- getOption("viewer")
  if (!is.null(viewer)){
    viewer(htmlFile)
  }
}
