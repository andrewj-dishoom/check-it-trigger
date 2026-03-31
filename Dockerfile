# Base R image
FROM rocker/tidyverse

# Set working directory inside the container
WORKDIR /app

# r libs 
RUN R -e "install.packages(c('httr','tidyverse','bigrquery'))" 

# Copy the R script to the container's working directory
COPY script.R /app/script.R

# Optional: Expose port if your script involves networking
EXPOSE 8080

# Command to execute when the container starts
CMD ["Rscript", "/app/script.R"]
