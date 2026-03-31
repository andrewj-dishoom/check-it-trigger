# Dockerized R Script for Google Cloud Integration

This repository contains a Dockerfile that packages an R script along with all the needed dependencies for execution within a Docker container. It's specifically designed for integration with Google Cloud services, utilizing `bigrquery`.

## Contents

*   **`Dockerfile`**: The Dockerfile containing instructions to build the image.
*   **`script.R`**:  The R script to be executed.

## Prerequisites

*   Docker installed on your machine.
*   Google Cloud SDK (gcloud CLI) installed and configured (if interacting with Google Cloud Container Registry).

## Usage

### Building the Docker Image

1.  Clone this repository:

    ```bash
    git clone <repository_url>
    cd <repository_directory>
    ```

2.  Build the Docker image:

    ```bash
    docker build -t my-r-app .
    ```

    Replace `my-r-app` with a suitable name for your image.

### Running the Docker Container

1.  Run the Docker image:

    ```bash
    docker run -p 8080:8080 my-r-app
    ```

    This will start the container and execute the `script.R` script.  The `-p 8080:8080` option maps port 8080 on the host machine to port 8080 inside the container, which is exposed by the Dockerfile.  Remove this if your script does not utilize port 8080.

### Interacting with Google Cloud

The `script.R` is designed to interact with Google Cloud using `bigrquery`. Ensure that:

*   The service account key file has the necessary permissions to access the Google Cloud resources (e.g., BigQuery datasets) your script requires.
*   Alternatively, and preferably, explore options to avoid storing the key in the image:
    *  Set `GOOGLE_APPLICATION_CREDENTIALS` environment variable to the path of the service account when running the container.
    *  Use Workload Identity if running on Google Kubernetes Engine (GKE) or other Google Cloud compute services.

### Pushing to Google Container Registry (Optional)

If you want to deploy the image to Google Cloud, you can push it to Google Container Registry (GCR):

1.  Authenticate to GCR:

    ```bash
    gcloud auth configure-docker
    ```

2.  Tag the image with your GCR registry URL:

    ```bash
    docker tag my-r-app gcr.io/jp-gs-379412/my-r-app
    ```

    Replace `jp-gs-379412` with your Google Cloud project ID.

3.  Push the image:

    ```bash
    docker push gcr.io/jp-gs-379412/my-r-app
    ```

## Notes

*   The `rocker/tidyverse` image provides a pre-configured R environment with common data science packages.
*   Modify `script.R` to suit your specific needs.
*   **Security:**  Storing service account keys directly in Docker images is **highly discouraged**.  Use a secure key management solution like Google Cloud Secret Manager or Workload Identity for production environments.  **Never commit the key file to a public repository.**
*   **Port Exposure:** The `EXPOSE 8080` directive in the Dockerfile informs Docker that the container will listen on port 8080 at runtime. This is informative and does not automatically publish the port. You must use the `-p` flag during `docker run` to actually publish the port to the host. Remove this if your script doesn't need it.

## Contributing

Feel free to contribute to this repository by submitting pull requests.
