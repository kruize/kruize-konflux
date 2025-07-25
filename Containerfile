#
# Copyright (c) 2020, 2021 Red Hat, IBM Corporation and others.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
##########################################################
#            Build Docker Image
##########################################################
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.5-1745855087 as mvnbuild-jdk21
ARG USER=autotune
ARG AUTOTUNE_HOME=/home/$USER

RUN microdnf --setopt=install_weak_deps=0 --setopt=tsflags=nodocs install -y java-21-openjdk-devel \
             tar gzip java-21-openjdk-jmods binutils git vim \
     && microdnf clean all 

RUN mkdir -p /usr/share/maven /usr/share/maven/ref \
  && curl -fsSL -o /tmp/apache-maven.tar.gz https://archive.apache.org/dist/maven/maven-3/3.9.11/binaries/apache-maven-3.9.11-bin.tar.gz \
  && tar -xzf /tmp/apache-maven.tar.gz -C /usr/share/maven --strip-components=1 \
  && rm -f /tmp/apache-maven.tar.gz \
  && ln -s /usr/share/maven/bin/mvn /usr/bin/mvn

WORKDIR $AUTOTUNE_HOME/src/autotune

# Copy only the pom.xml and download the dependencies
COPY autotune/pom.xml $AUTOTUNE_HOME/src/autotune/
RUN mvn -f pom.xml install dependency:copy-dependencies

# Now copy the sources and compile and package them
COPY autotune/src $AUTOTUNE_HOME/src/autotune/src/
RUN mvn -f pom.xml clean package
COPY autotune/migrations target/bin/migrations

# Create a jlinked JRE specific to the App
RUN jlink --strip-debug --compress 2 --no-header-files --no-man-pages --module-path $AUTOTUNE_HOME/java/openjdk/jmods --add-modules java.base,java.compiler,java.desktop,java.logging,java.management,java.naming,java.security.jgss,java.sql,java.xml,jdk.compiler,jdk.httpserver,jdk.unsupported,jdk.crypto.ec --exclude-files=**java_**.properties,**J9TraceFormat**.dat,**OMRTraceFormat**.dat,**j9ddr**.dat,**public_suffix_list**.dat --output jre

##########################################################
#            Runtime Docker Image
##########################################################
# Use ubi-minimal as the base image
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.5-1745855087

ARG AUTOTUNE_VERSION=test
ARG USER=autotune
ARG UID=1001
ARG AUTOTUNE_HOME=/home/$USER

ENV LANG='en_US.UTF-8' LANGUAGE='en_US:en' LC_ALL='en_US.UTF-8'

# Install packages needed for Java to function correctly
RUN microdnf --setopt=install_weak_deps=0 --setopt=tsflags=nodocs install -y tzdata openssl ca-certificates fontconfig \
             glibc-langpack-en gzip tar \
    && microdnf update -y \
    && microdnf clean all

COPY LICENSE /licenses/

LABEL name="Kruize Autotune" \
      vendor="Red Hat, Inc." \
      version=${AUTOTUNE_VERSION} \
      release=${AUTOTUNE_VERSION} \
      run="docker run --rm -it -p 8080:8080 <image_name:tag>" \
      summary="Docker Image for Autotune with ubi-minimal" \
      description="For more information on this image please see https://github.com/kruize/autotune/blob/master/README.md"

WORKDIR $AUTOTUNE_HOME/app

# Create the non root user, same as the one used in the build phase.
RUN microdnf -y install shadow-utils \
    && useradd -u ${UID} -s /usr/sbin/nologin default \
    && chown -R ${UID}:0 ${AUTOTUNE_HOME}/app \
    && chmod -R g+rw ${AUTOTUNE_HOME}/app \
    && microdnf -y remove shadow-utils \
    && microdnf clean all

# Switch to the non root user
USER ${UID}

# Copy the jlinked JRE
COPY --chown=${UID}:0 --from=mvnbuild-jdk21 ${AUTOTUNE_HOME}/src/autotune/jre/ ${AUTOTUNE_HOME}/app/jre/
# Copy the app binaries
COPY --chown=${UID}:0 --from=mvnbuild-jdk21 ${AUTOTUNE_HOME}/src/autotune/target/ ${AUTOTUNE_HOME}/app/target/

# Copy the metric and metadata profile JSON file path into the runtime image
COPY autotune/manifests/autotune/performance-profiles/resource_optimization_local_monitoring.json ${AUTOTUNE_HOME}/app/manifests/autotune/performance-profiles/resource_optimization_local_monitoring.json
COPY autotune/manifests/autotune/metadata-profiles/bulk_cluster_metadata_local_monitoring.json ${AUTOTUNE_HOME}/app/manifests/autotune/metadata-profiles/bulk_cluster_metadata_local_monitoring.json

# Grant execute permission
RUN chmod -R +x $AUTOTUNE_HOME/app/target/bin/

EXPOSE 8080

ENV JAVA_HOME=${AUTOTUNE_HOME}/app/jre \
    PATH="${AUTOTUNE_HOME}/app/jre/bin:$PATH"

ENTRYPOINT bash target/bin/Autotune

