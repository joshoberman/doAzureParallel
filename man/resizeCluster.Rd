% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/autoscale.R
\name{resizeCluster}
\alias{resizeCluster}
\title{Resize an Azure cloud-enabled cluster.}
\usage{
resizeCluster(cluster, dedicatedMin, dedicatedMax, lowPriorityMin,
  lowPriorityMax, algorithm = "QUEUE", timeInterval = "PT5M")
}
\arguments{
\item{cluster}{Cluster object that was referenced in \code{makeCluster}}

\item{dedicatedMin}{The minimum number of dedicated nodes}

\item{dedicatedMax}{The maximum number of dedicated nodes}

\item{lowPriorityMin}{The minimum number of low priority nodes}

\item{lowPriorityMax}{The maximum number of low priority nodes}

\item{algorithm}{Current built-in autoscale formulas: QUEUE, MAX_CPU, WEEKEND, WEEKDAY}

\item{timeInterval}{}
}
\description{
Resize an Azure cloud-enabled cluster.
}
\examples{
resizeCluster(cluster, dedicatedMin = 2, dedicatedMax = 6, dedicatedMin = 2, dedicatedMax = 6, algorithm = "QUEUE", timeInterval = "PT10M")
}

