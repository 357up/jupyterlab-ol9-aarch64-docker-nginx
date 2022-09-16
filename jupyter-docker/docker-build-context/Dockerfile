FROM jupyter/datascience-notebook:aarch64-latest

# Install some missing system packages
USER root

RUN apt update && apt install -y zip unzip vim iproute2 iputils-ping netcat
RUN apt clean && rm -rf /var/lib/apt/lists/*
COPY --chown=root:root --chmod=755 generate_token.py /usr/local/bin/generate_token.py

USER jovyan

# Override default settings
COPY ./overrides.json /opt/conda/share/jupyter/lab/settings/

# Configue SSH client
RUN mkdir ~/.ssh && printf \
    "Host *\n\tUser opc\n\tServerAliveInterval 120\n\tStrictHostKeyChecking no\
    UserKnownHostsFile=/dev/null\n\tForwardAgent yes\n\tAddKeysToAgent yes\n" \
    > ~/.ssh/config

# Set up DNS override for docker host (Default gateway address)
RUN echo "172.18.80.1 host"

# Install some addtional JupyterLab extentions

# https://anaconda.org/conda-forge/jupytext
RUN conda install -y -c conda-forge jupytext \
    && jupyter labextension enable @jupyterlab/jupytext

# # https://github.com/codota/tabnine-jupyterlab
# # https://www.tabnine.com/pricing
# RUN pip3 install --no-cache-dir jupyterlab_tabnine \
#     && jupyter labextension enable jupyterlab_tabnine \
#     && jupyter serverextension enable jupyterlab_tabnine
    
# https://github.com/jupyterlab/jupyterlab-git
RUN conda install -y -c conda-forge jupyterlab-git \
    && jupyter labextension enable @jupyterlab/git

# # https://github.com/jupyterlab/jupyterlab-google-drive
# #  Disabled because currently does not support JupyterLab >=3.0
# RUN jupyter labextension install @jupyterlab/google-drive \
#     && jupyter labextension enable @jupyterlab/google-drive

# https://github.com/ryantam626/jupyterlab_code_formatter
RUN conda install -c conda-forge jupyterlab_code_formatter \
    && pip3 install --no-cache-dir black isort \
    && jupyter labextension enable @jupyterlab/jupyterlab_code_formatter

# https://github.com/AllanChain/jupyterlab-theme-solarized-dark
RUN jupyter labextension install jupyterlab-theme-solarized-dark \
    && jupyter labextension enable jupyterlab-theme-solarized-dark

# https://github.com/plotly/plotly.py#readme
RUN jupyter labextension install --clean plotlywidget \
    && jupyter labextension enable plotlywidget \
    && pip3 install --no-cache-dir plotly ipywidgets kaleido

RUN echo "$(jupyter labextension list)"