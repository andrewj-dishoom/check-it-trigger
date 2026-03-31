library(httr)
library(tidyverse)
library(bigrquery)

# *** authkey runs out after a month, new code has to be generated within CheckIt ***

path_to_json <- Sys.getenv("_JSON_SECRET")
authKey <-  Sys.getenv("_AUTH_KEY")
baseUrl <- "https://reports.checkit.net/api"
locations <- "/locations"
jobs <- "/jobs"
reports <- "/reports"

start_date <- format(Sys.Date()-100,"%d-%m-%Y")
end_date <- format(Sys.Date(),"%d-%m-%Y")

event_type <- "checkReport,jobOverdue,jobCancelled,sensorAlert,zigbeeBatteryAlert"

get_data <- function(base_url, endpoint, auth_token, start_date = NULL, end_date = NULL, event_type = NULL, service_type = NULL) {
  
  all_data <- list()
  
  if (!is.null(start_date) && !is.null(end_date)) {
    dates <- seq.Date(as.Date(start_date, format = "%d-%m-%Y"), as.Date(end_date, format = "%d-%m-%Y"), by = "day")
  } else {
    dates <- c(NA)
  }
  
  for (current_date in dates) {
    
    query <- list()
    
    if (endpoint == "/locations") {
      # No query needed
    } else if (endpoint == "/jobs" && !is.na(current_date)) {
      formatted_current_date <- as.Date(current_date, format = "%d-%m-%Y")
      formatted_for_query_start <- format(formatted_current_date, "%d-%m-%Y")
      formatted_for_query_end <- format(formatted_current_date + 1, "%d-%m-%Y")
      
      query <- list(
        limit = "1000",  # ✅ Minimal fix: add valid limit
        start_time = formatted_for_query_start,
        end_time = formatted_for_query_end
      )
      
    } else if (endpoint == "/reports" && !is.na(current_date)) {
      formatted_current_date <- as.Date(current_date, format = "%d-%m-%Y")
      formatted_for_query_start <- format(formatted_current_date, "%d-%m-%Y")
      formatted_for_query_end <- format(formatted_current_date + 1, "%d-%m-%Y")
      
      query <- list(
        limit = "",
        start_time = formatted_for_query_start,
        end_time = formatted_for_query_end,
        event_type = event_type,
        service_type = service_type
      )
    }
    
    response <- tryCatch({
      GET(
        url = paste0(base_url, endpoint),
        query = query,
        add_headers(
          Authorization = paste("Bearer", auth_token),
          Accept = "text/csv"
        )
      )
    }, error = function(e) {
      message("An error occurred: ", e$message)
      return(NULL)
    })
    
    if (!is.null(response) && status_code(response) == 200) {
      message("Request was successful.")
      content_text <- rawToChar(response$content)
      data <- read.csv(text = content_text, stringsAsFactors = FALSE)
      all_data <- append(all_data, list(data))
    } else {
      warning("Request failed with status: ", status_code(response))
    }
  }
  
  combined_data <- do.call(rbind, lapply(all_data, as.data.frame))
  return(combined_data)
}

# locations request
location_data <- get_data(baseUrl, locations, authKey)

# jobs request
job_data <- get_data(baseUrl, jobs, authKey, start_date, end_date)
cat("Rows in job_data:", nrow(job_data), "\n")  # ✅ Minimal logging to confirm job data is returned

# reports
report_data_workmanagement <- get_data(baseUrl, reports,  authKey, start_date,  end_date, event_type = NULL, service_type = "workmanagement")
report_data_automatedmonitoring <- get_data(baseUrl, reports,  authKey, start_date,  end_date, event_type, service_type = "automatedmonitoring")

bq_deauth()
bq_auth(path = path_to_json)

project_id <- "jp-gs-379412"
dataset_id <- "CheckIt"

dataframes <- list(
  report_data = report_data_workmanagement,
  alerts_data = report_data_automatedmonitoring,
  location_data = location_data,
  job_data = job_data
)

upload_to_bigquery <- function(df, table_name) {
  dataset_ref <- bq_dataset(project_id, dataset_id)
  table_ref <- bq_table(dataset_ref, table_name)
  
  tryCatch({
    bq_table_meta(table_ref)
    cat("Table", table_name, "already exists.\n")
  }, error = function(e) {
    cat("Table", table_name, "does not exist. Creating it now.\n")
    bq_table_create(
      table_ref,
      fields = as_bq_fields(df)
    )
  })
  
  bq_table_upload(
    table_ref,
    df,
   # source_format = "CSV",
    write_disposition = "WRITE_TRUNCATE"
  )
  
  cat("Dataframe successfully uploaded to BigQuery table:", table_name, "\n")
}

# Iterate over and upload each dataframe
for (i in names(dataframes)) {
  df <- tryCatch(as.data.frame(dataframes[[i]]), error = function(e) NULL)
  if (!is.null(df) && nrow(df) > 0) {
    upload_to_bigquery(df, i)
  } else {
    cat("Skipping upload for", i, "because it could not be coerced into a valid data frame or contains no rows.\n")
  }
}
