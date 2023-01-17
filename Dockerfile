ARG ARCH=arm64v8
# docker pull sickcodes/docker-osx:ventura

from $ARCH/ubuntu:22.04 AS wget
RUN apt-get update \
    && apt-get install -y wget \
    && rm -rf /var/lib/apt/lists/*

ARG PYTHON_VERSION='3.9'
ARG ANACONDA3_VERSION='2022.10'
ARG ARCH=${ARCH}

### getting conda for different plattforms
from wget AS anaconda-arm64v8
WORKDIR /tmp/
RUN wget "https://repo.anaconda.com/archive/Anaconda3-$ANACONDA3_VERSION-Linux-aarch64.sh" -O "./anaconda3_$ARCH.sh"

from wget AS anaconda-amd64
RUN wget "https://repo.anaconda.com/archive/Anaconda3-$ANACONDA3_VERSION-Linux-x86_64.sh" -O "./anaconda3_$ARCH.sh"

from wget AS anaconda-ppc64le
RUN wget "https://repo.anaconda.com/archive/Anaconda3-$ANACONDA3_VERSION-Linux-$ARCH.sh" -O "./anaconda3_$ARCH.sh" 

from wget AS anaconda-s390x
RUN wget "https://repo.anaconda.com/archive/Anaconda3-$ANACONDA3_VERSION-Linux-$ARCH.sh" -O "./anaconda3_$ARCH.sh" 


FROM anaconda-${ARCH} as conda_build
SHELL [ "/bin/bash", "-c" ]
ENV CONDA_INSTALL_DIR /opt/anaconda
ARG ARCH ${ARCH}
WORKDIR /tmp/
RUN /bin/bash ./anaconda3_${ARCH}.sh -b -p${CONDA_INSTALL_DIR} \
    && rm ./anaconda3_${ARCH}.sh

RUN source ${CONDA_INSTALL_DIR}/bin/activate \
    && conda init \
    && conda update -y conda 

FROM conda_build AS ocp_lib_base
RUN apt-get update --allow-insecure-repositories \
    && DEBIAN_FRONTEND=noninteractiv apt-get install -y \
        ninja-build mesa-common-dev libegl1-mesa-dev libgl1-mesa-dev libglu1-mesa-dev freeglut3-dev \
        libvtk9-dev \
        qtcreator qtbase5-dev \
        rapidjson-dev \
    && rm -rf /var/lib/apt/lists/*

FROM ocp_lib_base AS ocp_compiler_base
RUN apt-get update --allow-insecure-repositories \
    && apt-get install -y software-properties-common 

RUN add-apt-repository -y universe

RUN apt-get update --allow-insecure-repositories \
    && apt-get install -y \
        wget \
        git \
        build-essential \
        cmake \
        clang \
        lldb \
        lld \
        ccache \
    && apt-get -y upgrade \
    && rm -rf /var/lib/apt/lists/*


FROM ocp_compiler_base as ocp_build
SHELL [ "/bin/bash", "-c" ]

COPY ./OCP /opt/OCP
WORKDIR /opt/OCP
ENV CONDA_ENV="env.yml"
ENV CPP_PY_BINDGEN=${CONDA_INSTALL_DIR}/envs/cpp-py-bindgen

RUN source ${CONDA_INSTALL_DIR}/bin/activate \
    && sed -e s/python=.../python=$PYTHON_VERSION/  ${CONDA_ENV} > _${CONDA_ENV} \
    && conda init \
    && conda env create -f _env.yml \
    && conda install -n cpp-py-bindgen -y python=${PYTHON_VERSION}

RUN source ${CONDA_INSTALL_DIR}/bin/activate cpp-py-bindgen \
    && touch /tmp/conda_env.log \
    && conda info -a >> /tmp/conda_env.log\
    && conda list >> /tmp/conda_env.log\
    && which python >> /tmp/conda_env.log\
    && env >> /tmp/conda_env.log

RUN source ${CONDA_INSTALL_DIR}/bin/activate cpp-py-bindgen
RUN export OUTPUT=$(python -c "import toml; print(toml.load('ocp.toml')['output_folder'])")

# im ocp.toml steht >> output_folder = "./OCP"
# FROM ocp_build as call_pywrap
# SHELL [ "/bin/bash", "-c" ]
# WORKDIR /opt/OCP
# #CMake based pywrap call
# RUN source ${CONDA_INSTALL_DIR}/bin/activate cpp-py-bindgen \
#     && echo "find_package(Python3 $PYTHON_VERSION EXACT COMPONENTS Development REQUIRED)" > test.cmake \
#     && cmake --debug-find -DPython3_FIND_VIRTUALENV=ONLY -P test.cmake \
#     && cmake -DPython3_EXECUTABLE=/opt/anaconda/envs/cpp-py-bindgen/bin/python \
#     -DPython3_ROOT_DIR=${CONDA_INSTALL_DIR}/envs/cpp-py-bindgen -B new -S . -G Ninja


FROM ocp_build as ocp_build_makefiles
SHELL [ "/bin/bash", "-c" ]
WORKDIR /opt/OCP
ENV CPP_PY_BINDGEN=${CONDA_INSTALL_DIR}/envs/cpp-py-bindgen

RUN source ${CONDA_INSTALL_DIR}/bin/activate cpp-py-bindgen \
    && cmake -DPython3_FIND_VIRTUALENV=ONLY -DPython3_EXECUTABLE=${CPP_PY_BINDGEN}/bin/python \
    -DPython3_ROOT_DIR=${CPP_PY_BINDGEN} -B build -S ../OCP -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER_LAUNCHER="ccache" -DCMAKE_CXX_COMPILER_LAUNCHER="ccache"

FROM ocp_build_makefiles as ocp_base
SHELL [ "/bin/bash", "-c" ]
WORKDIR /opt/OCP
RUN cmake --build build -j 4 -- -k 0; exit 0 
RUN cmake --build build -j 2 -- -k 0; exit 0 
RUN cmake --build build -- -k 0; exit 0 
RUN cmake --build build -- -k 0 \
    && cmake --install build 

# test - 
RUN source ${CONDA_INSTALL_DIR}/bin/activate \
    && cd build \
    && LD_DEBUG=libs python -c"import OCP;"


FROM ocp_base as build_conda_package
WORKDIR /opt/OCP
ENV PYTHON_VERSION=${PYTHON_VERSION}
RUN source ${CONDA_INSTALL_DIR}/bin/activate \
    && conda install -y conda-build \
    && conda create -y -n conda-build -y python=${PYTHON_VERSION} 

RUN source ${CONDA_INSTALL_DIR}/bin/activate \
    && conda activate conda-build \
    && PYTHON_VERSION=${PYTHON_VERSION} conda build -c conda-forge -c conda-forge/label/occt_rc conda

FROM conda_build AS cq_lib_base
RUN apt-get update --allow-insecure-repositories \
    && DEBIAN_FRONTEND=noninteractiv apt-get install -y \
        libegl1-mesa libglu1-mesa freeglut3 \
        libvtk9.1 \
        rapidjson-dev \
    && rm -rf /var/lib/apt/lists/*


FROM cq_lib_base AS cadquery_build_base
WORKDIR /opt/cadquery
COPY ./cadquery .
#COPY ./conda-bld /opt/anaconda/conda-bld

COPY --from=build_conda_package ${CONDA_INSTALL_DIR}/conda-bld ${CONDA_INSTALL_DIR}/conda-bld
RUN sed -e 's/\"cadquery-ocp/#\"cadquery-ocp/'  setup.py > _setup.py \
    && sed -e 's/use_scm_version=.*,/use_scm_version=False,/' _setup.py > setup.py \
    && sed -e 's/defaults/defaults\n  - local/' environment.yml > _environment.yml && mv _environment.yml environment.yml

FROM cadquery_build_base as cadquery_build
ENV export PACKAGE_VERSION=2.1
ENV PYTHON_VERSION=${PYTHON_VERSION}
RUN source ${CONDA_INSTALL_DIR}/bin/activate \
    && conda install -y conda-build \
    && conda create -y -n conda-build -y python=${PYTHON_VERSION}

RUN source ${CONDA_INSTALL_DIR}/bin/activate conda-build \
    && PYTHON_VERSION=${PYTHON_VERSION} conda build -c conda-forge -c local conda


FROM cq_lib_base AS cadquery
# COPY ./conda-bld /opt/anaconda/conda-bld
COPY --from=cadquery_build ${CONDA_INSTALL_DIR}/conda-bld ${CONDA_INSTALL_DIR}/conda-bld

SHELL [ "/bin/bash", "-c" ]
#Create a new group
RUN useradd -s /usr/bin/bash cadquery \
    && groupadd anaconda \
    && chgrp -R anaconda ${CONDA_INSTALL_DIR} \
    && chmod 770 -R ${CONDA_INSTALL_DIR} \
    && adduser cadquery anaconda

USER cadquery
SHELL [ "/bin/bash", "-c" ]

WORKDIR /home/cadquery
RUN source ${CONDA_INSTALL_DIR}/bin/activate \
    && conda create -n cadquery \
    && conda activate cadquery \
    && conda install -c conda-forge -c local cadquery python=${PYTHON_VERSION} ocp=7.6.* 

RUN source ${CONDA_INSTALL_DIR}/bin/activate \
    && conda clean -y -a \
    && conda env export > environment.yml \
    && du -hs ${CONDA_INSTALL_DIR}

CMD source ${CONDA_INSTALL_DIR}/bin/activate && conda init && conda activate cadquery && echo "Welcome to cadquery" && /usr/bin/bash
#ENTRYPOINT ["/bin/bash"]