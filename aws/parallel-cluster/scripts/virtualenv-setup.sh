#!/bin/bash

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
elif [ "$ARCH" = "aarch64" ]; then
    MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

# Install Miniconda
wget $MINICONDA_URL -O /tmp/miniconda.sh
bash /tmp/miniconda.sh -b -p /tmp/miniconda

# Setup environment
/tmp/miniconda/bin/conda create -y -n weka-temp-venv python=3.9
source /tmp/miniconda/bin/activate weka-temp-venv

# Install Python packages
conda install -y anaconda::boto3 anaconda::requests anaconda::psutil

# Cleanup
conda deactivate
