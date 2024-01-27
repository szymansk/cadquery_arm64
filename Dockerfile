ARG TARGETARCH=arm64v8
ARG BASE_IMAGE=ubuntu:22.04
ARG BASE="${TARGETARCH}/${BASE_IMAGE}"
# docker pull sickcodes/docker-osx:ventura

FROM ${TARGETARCH}/ubuntu:22.04 AS wget
RUN apt-get update \
    && apt-get install -y \
        wget \
        software-properties-common \
    && rm -rf /var/lib/apt/lists/*

ARG PYTHON_VERSION='3.11'
ARG CONDA_DIST='miniconda3'
ARG CONDA_VERSION='2023.09-0'
ARG ARCH=${TARGETARCH}

### getting conda for different plattforms
FROM wget AS anaconda-arm64v8
WORKDIR /tmp/
#RUN wget "https://repo.anaconda.com/archive/Anaconda3-$CONDA_VERSION-Linux-aarch64.sh" -O "./anaconda3_$ARCH.sh"
RUN wget "https://repo.anaconda.com/miniconda/Miniconda3-py311_23.11.0-2-Linux-aarch64.sh" -O "./miniconda3_$ARCH.sh"

FROM wget AS anaconda-amd64
WORKDIR /tmp/
RUN wget "https://repo.anaconda.com/archive/Anaconda3-$CONDA_VERSION-Linux-x86_64.sh" -O "./anaconda3_$ARCH.sh"

FROM wget AS anaconda-ppc64le
WORKDIR /tmp/
RUN wget "https://repo.anaconda.com/archive/Anaconda3-$CONDA_VERSION-Linux-$ARCH.sh" -O "./anaconda3_$ARCH.sh" 

FROM wget AS anaconda-s390x
WORKDIR /tmp/
RUN wget "https://repo.anaconda.com/archive/Anaconda3-$CONDA_VERSION-Linux-$ARCH.sh" -O "./anaconda3_$ARCH.sh" 


FROM anaconda-${TARGETARCH} as conda_build
SHELL [ "/bin/bash", "-c" ]
ENV CONDA_INSTALL_DIR=/opt/anaconda
ARG ARCH=${TARGETARCH}
WORKDIR /tmp/
RUN /bin/bash ./miniconda3_${ARCH}.sh -b -p${CONDA_INSTALL_DIR} \
    && rm ./miniconda3_${ARCH}.sh

#RUN /bin/bash ./anaconda3_${ARCH}.sh -b -p${CONDA_INSTALL_DIR} \
#    && rm ./anaconda3_${ARCH}.sh

RUN source ${CONDA_INSTALL_DIR}/bin/activate \
    && conda init \
    && conda update -y conda 

#######################
###### OCP BUILD ######
#######################
FROM conda_build AS ocp_lib_base
RUN add-apt-repository -y universe
RUN apt-get update --allow-insecure-repositories \
    && DEBIAN_FRONTEND=noninteractiv apt-get -y install \
        --no-install-recommends \
        mesa-common-dev libegl1-mesa-dev libgl1-mesa-dev libglu1-mesa-dev freeglut3-dev \
        libvtk9-dev \
        qtcreator qtbase5-dev \
        rapidjson-dev \
        git \
        build-essential \
        cmake \
        clang \
        lldb \
        lld \
        ccache \
        ninja-build \
    && apt-get -y upgrade \
    && apt-get clean \
    && apt-get autoremove \
    && rm -rf /var/lib/apt/lists/*


FROM ocp_lib_base as ocp_copy
ARG OCP_COMMIT=occt772
RUN git clone https://github.com/CadQuery/OCP.git /opt/OCP \
    && cd /opt/OCP \
    && git submodule update --init --recursive \
    && git checkout ${OCP_COMMIT}

FROM ocp_copy as ocp_build
SHELL [ "/bin/bash", "-c" ]

# COPY ./OCP /opt/OCP
WORKDIR /opt/OCP
ENV CONDA_ENV='environment.devenv.yml'
ENV CPP_PY_BINDGEN=${CONDA_INSTALL_DIR}/envs/cpp-py-bindgen

RUN sed -e 's/libcxx=.*/libcxx=/' \
    -e 's/boost=.*/boost=1.84.*/'  \     
    -e "s/python=.*/python=${PYTHON_VERSION}/" ${CONDA_ENV} > _env.yml    

RUN source ${CONDA_INSTALL_DIR}/bin/activate \
    && conda init \
    && conda update -y conda \
    && conda env create -f _env.yml -vv \
    && conda install -n cpp-py-bindgen -y python=${PYTHON_VERSION} \
    && conda info -a \
    && conda list \
    && which python \
    && env


FROM ocp_build as ocp_build_pywrap
SHELL [ "/bin/bash", "-c" ]
WORKDIR /opt/OCP

# build occt bindings with pywrap
RUN source ${CONDA_INSTALL_DIR}/bin/activate cpp-py-bindgen \
    && cmake -DPython_ROOT_DIR=$CONDA_PREFIX -DPython3_ROOT_DIR=$CONDA_PREFIX \
          -DPython_FIND_VIRTUALENV=ONLY -DPython3_FIND_VIRTUALENV=ONLY \
          -B new -S . -G Ninja

FROM ocp_build_pywrap as ocp_build_makefiles
SHELL [ "/bin/bash", "-c" ]
WORKDIR /opt/OCP
# generate occt wrapper Makefiles
RUN source ${CONDA_INSTALL_DIR}/bin/activate cpp-py-bindgen \
    && cmake -B build -S ./OCP -G Ninja -DCMAKE_BUILD_TYPE=Release

FROM ocp_build_makefiles as ocp_base
SHELL [ "/bin/bash", "-c" ]
WORKDIR /opt/OCP

# build occt wrapper
RUN cmake --build build -j 4 -- -k 0; exit 0
RUN cmake --build build -j 2 -- -k 0; exit 0
RUN cmake --build build -- -k 0 \
    && cmake --install build \
    && rm -rf build/CMakeFiles 

# test - 
RUN source ${CONDA_INSTALL_DIR}/bin/activate \
    && cd build \
    && LD_DEBUG=libs python -c"import OCP;"


FROM ocp_base as build_conda_package
WORKDIR /opt/OCP
ENV PYTHON_VERSION=${PYTHON_VERSION}

#RUN conda create -n build -y -c conda-forge python=${PYTHON_VERSION} conda-build anaconda-client && \
#    && source ${CONDA_INSTALL_DIR}/bin/activate build \
#    && conda build --token $TOKEN --user cadquery --label dev -c conda-forge --override-channels conda

RUN source ${CONDA_INSTALL_DIR}/bin/activate \
    && conda install -y conda-build \
    && conda create -y -n conda-build -y python=${PYTHON_VERSION} 

RUN source ${CONDA_INSTALL_DIR}/bin/activate \
    && conda activate conda-build \
    && sed -i.bak  -e 's/ noarch: python//' conda/meta.yaml \
    && PYTHON_VERSION=${PYTHON_VERSION} conda build -c conda-forge -c conda-forge/label/occt_rc conda \
    && conda build purge

#########################
###### CONDA BUILD ######
#########################
FROM conda_build AS cq_lib_base
RUN apt-get update --allow-insecure-repositories \
    && DEBIAN_FRONTEND=noninteractiv apt-get -y install \
        --no-install-recommends \
        libegl1-mesa libglu1-mesa freeglut3\
        libvtk9.1 \
        rapidjson-dev \
        git \
    && apt-get clean \
    && apt-get autoremove \
    && rm -rf /var/lib/apt/lists/*

FROM cq_lib_base AS cadquery_build_base
WORKDIR /opt/cadquery
ARG CADQUERY_COMMIT=2.4.0
RUN git clone https://github.com/CadQuery/cadquery.git /opt/cadquery \
    && git checkout tags/${CADQUERY_COMMIT}

COPY --from=build_conda_package ${CONDA_INSTALL_DIR}/conda-bld ${CONDA_INSTALL_DIR}/conda-bld

FROM cadquery_build_base as cadquery_build_ezdxf
WORKDIR /opt
ARG EZDXF_TAG=v1.1.4
#export EZDXF_TAG=v1.1.4
#export PYTHON_VERSION=3.11

RUN source ${CONDA_INSTALL_DIR}/bin/activate \
    && git clone https://github.com/mozman/ezdxf.git\
    && cd ezdxf \
    && git checkout tags/${EZDXF_TAG} \
    && conda install -y -c conda-forge cython grayskull conda-build pytest python=${PYTHON_VERSION} \
    && grayskull pypi --strict-conda-forge ezdxf \
    && sed -i.bak  -e 's/ noarch: python//' ezdxf/meta.yaml \
    && conda build -c local -c conda-forge . && \ 
    conda install -y --use-local ezdxf \
    && pytest \
    && conda build purge \
    && conda remove -y cython grayskull conda-build pytest


FROM cadquery_build_ezdxf as cadquery_build
ARG PACKAGE_VERSION=2.4
ARG PYTHON_VERSION=${PYTHON_VERSION}
WORKDIR /opt/cadquery

RUN sed -i.bak -e 's/ezdxf/ezdxf=1.1.4 - local/' \
        -e 's/ocp=7.7.2/ocp=7.7.2 - local/' environment.yml 

RUN sed -i.bak -e 's/ezdxf/ezdxf=1.1.4/' conda/meta.yaml

RUN source ${CONDA_INSTALL_DIR}/bin/activate \
    && conda install -y conda-build \
    && conda create -y -n conda-build -y python=${PYTHON_VERSION}

RUN source ${CONDA_INSTALL_DIR}/bin/activate conda-build \
    && PYTHON_VERSION=${PYTHON_VERSION} conda build -c conda-forge -c local conda 

RUN source ${CONDA_INSTALL_DIR}/bin/activate conda-build \
    && conda build purge \
    && conda clean --all

FROM cq_lib_base AS cadquery
COPY --from=cadquery_build ${CONDA_INSTALL_DIR}/conda-bld ${CONDA_INSTALL_DIR}/conda-bld
SHELL [ "/bin/bash", "-c" ]

WORKDIR /home/cadquery
RUN source ${CONDA_INSTALL_DIR}/bin/activate \
    && conda create -y -n cadquery \
    && conda activate --no-stack cadquery \
    && conda install --use-local -y -c conda-forge -c local cadquery python=${PYTHON_VERSION} ocp 

RUN source ${CONDA_INSTALL_DIR}/bin/activate \
    && conda activate --no-stack  cadquery \
    && apt-get clean \
    && apt-get autoremove \
    && conda clean --all \
    && du -hs ${CONDA_INSTALL_DIR}

CMD source ${CONDA_INSTALL_DIR}/bin/activate && conda init && conda activate cadquery && echo "Welcome to cadquery" && /usr/bin/bash


FROM cadquery AS cadquery-client
SHELL [ "/bin/bash", "-c" ]
WORKDIR /home/cadquery

RUN apt-get update --allow-insecure-repositories \
    && DEBIAN_FRONTEND=noninteractiv apt-get -y install \
        --no-install-recommends \
        gcc python3-dev \
    && apt-get clean \
    && apt-get autoremove \
    && rm -rf /var/lib/apt/lists/*

RUN source ${CONDA_INSTALL_DIR}/bin/activate \
    && conda init \
    && conda activate cadquery \
    && conda install -y -c conda-forge requests matplotlib \
    && pip install jupyter-cadquery==3.5.2 cadquery-massembly==1.0.0 \
    && conda activate cadquery \
    && conda clean --all

RUN git clone --depth 1 https://github.com/PhilippFr/cadquery-server.git cs 

RUN echo "conda activate cadquery" >> /root/.bashrc

#ENTRYPOINT ["/bin/bash"]


FROM cadquery-client AS cadquery_reduced
SHELL [ "/bin/bash", "-c" ]

RUN source ${CONDA_INSTALL_DIR}/bin/activate \
    && conda install -c conda-forge conda-pack

RUN source ${CONDA_INSTALL_DIR}/bin/activate \
    && conda-pack -n cadquery -o /tmp/env.tar \
    && mkdir /venv && cd /venv && tar xf /tmp/env.tar \
    && rm /tmp/env.tar

RUN source ${CONDA_INSTALL_DIR}/bin/activate \
    && /venv/bin/conda-unpack


FROM ${TARGETARCH}/ubuntu:22.04 AS runtime
SHELL [ "/bin/bash", "-c" ]
WORKDIR /home/cadquery

# Copy /venv from the previous stage:
COPY --from=cadquery_reduced /venv /venv
COPY --from=cadquery-client /home/cadquery/cs /home/cadquery/cs

RUN apt-get update \
    && apt-get install -y \
        software-properties-common \
    && add-apt-repository -y universe 

RUN apt-get update --allow-insecure-repositories \
    && DEBIAN_FRONTEND=noninteractiv apt-get -y install \
        --no-install-recommends \
        libegl1-mesa libglu1-mesa freeglut3\
        libvtk9.1 \
        rapidjson-dev \
    && apt-get clean \
    && apt-get autoremove \
    && rm -rf /var/lib/apt/lists/*

RUN echo "source /venv/bin/activate" >> /root/.bashrc


#ENTRYPOINT source /venv/bin/activate && \
#           python -c "import cadquery; print('success!')" && \
#           python example/usage_example.py
