#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OPENMP_VERSION="${OPENMP_VERSION:-18.1.2}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-13.0}"
ENABLE_BITCODE="${ENABLE_BITCODE:-OFF}"
ENABLE_ARC="${ENABLE_ARC:-OFF}"
ENABLE_VISIBILITY="${ENABLE_VISIBILITY:-OFF}"
VULKAN="${NCNN_VULKAN:-ON}"

BUILD_ROOT="${SCRIPT_DIR}/build_ios"
DOWNLOAD_DIR="${BUILD_ROOT}/downloads"
OPENMP_SRC_DIR="${BUILD_ROOT}/openmp-${OPENMP_VERSION}.src"
CMAKE_SRC_DIR="${BUILD_ROOT}/cmake-${OPENMP_VERSION}.src"
OPENMP_BUILD_DIR="${OPENMP_SRC_DIR}/build-arm64"
OPENMP_INSTALL_DIR="${OPENMP_BUILD_DIR}/install"
OPENMP_HEADER_DIR="${OPENMP_INSTALL_DIR}/include"
OPENMP_LIBRARY_FILE="${OPENMP_INSTALL_DIR}/lib/libomp.a"
NCNN_BUILD_DIR="${BUILD_ROOT}/ncnn-build-arm64"
NCNN_INSTALL_DIR="${BUILD_ROOT}/install-ios-arm64"
PACKAGE_DIR="${BUILD_ROOT}/package-ios-arm64"

PATCH_1="ef8c35bcf5d9cfdb0764ffde6a63c04ec715bc37.patch"
PATCH_2="5c12711f9a21f41bea70566bf15a4026804d6b20.patch"

CLEAN=0

usage() {
  cat <<EOF
Usage: ./build_ios.sh [options]

Options:
  --vulkan ON|OFF   Build ncnn with Vulkan (default: ON)
  --clean           Clean ${BUILD_ROOT} build outputs before building
  -h, --help        Show this help

Environment overrides:
  OPENMP_VERSION
  IOS_DEPLOYMENT_TARGET
  ENABLE_BITCODE
  ENABLE_ARC
  ENABLE_VISIBILITY
  NCNN_VULKAN
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vulkan)
      [[ $# -lt 2 ]] && { echo "missing value for --vulkan"; exit 1; }
      VULKAN="$2"
      shift 2
      ;;
    --vulkan=*)
      VULKAN="${1#*=}"
      shift
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ "${VULKAN}" != "ON" && "${VULKAN}" != "OFF" ]]; then
  echo "--vulkan must be ON or OFF"
  exit 1
fi

require_tools() {
  local tools=(
    cmake
    curl
    tar
    patch
    git
    libtool
    xcrun
    zip
    sed
  )
  local t
  for t in "${tools[@]}"; do
    if ! command -v "${t}" >/dev/null 2>&1; then
      echo "required tool not found: ${t}"
      exit 1
    fi
  done
}

num_jobs() {
  local n
  n="$(sysctl -n hw.ncpu 2>/dev/null || true)"
  if [[ -z "${n}" ]]; then
    n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  fi
  if [[ -z "${n}" ]]; then
    n=8
  fi
  echo "${n}"
}

ensure_submodules() {
  if [[ -f "${SCRIPT_DIR}/glslang/CMakeLists.txt" ]]; then
    return
  fi

  echo "[submodule] glslang missing, initializing submodules"
  if ! git -C "${SCRIPT_DIR}" submodule update --init --recursive; then
    echo "failed to initialize submodules; run manually:"
    echo "  git submodule update --init --recursive"
    exit 1
  fi
}

ensure_dir() {
  mkdir -p "$1"
}

download_file() {
  local url="$1"
  local output="$2"
  if [[ ! -f "${output}" ]]; then
    echo "[download] ${url}"
    curl -L -o "${output}" "${url}"
  fi
}

prepare_openmp_source() {
  ensure_dir "${BUILD_ROOT}"
  ensure_dir "${DOWNLOAD_DIR}"

  local cmake_tar="${DOWNLOAD_DIR}/cmake-${OPENMP_VERSION}.src.tar.xz"
  local openmp_tar="${DOWNLOAD_DIR}/openmp-${OPENMP_VERSION}.src.tar.xz"

  download_file "https://github.com/llvm/llvm-project/releases/download/llvmorg-${OPENMP_VERSION}/cmake-${OPENMP_VERSION}.src.tar.xz" "${cmake_tar}"
  download_file "https://github.com/llvm/llvm-project/releases/download/llvmorg-${OPENMP_VERSION}/openmp-${OPENMP_VERSION}.src.tar.xz" "${openmp_tar}"

  if [[ ! -d "${CMAKE_SRC_DIR}" ]]; then
    echo "[extract] ${cmake_tar}"
    tar -C "${BUILD_ROOT}" -xf "${cmake_tar}"
  fi

  if [[ ! -d "${OPENMP_SRC_DIR}" ]]; then
    echo "[extract] ${openmp_tar}"
    tar -C "${BUILD_ROOT}" -xf "${openmp_tar}"
  fi

  cp -f "${CMAKE_SRC_DIR}/Modules/"* "${OPENMP_SRC_DIR}/cmake/"
}

apply_openmp_patches() {
  local marker="${OPENMP_SRC_DIR}/.ios_patch_applied"
  if [[ -f "${marker}" ]]; then
    return
  fi

  pushd "${OPENMP_SRC_DIR}" >/dev/null
  download_file "https://github.com/nihui/llvm-project/commit/${PATCH_1}" "${PATCH_1}"
  patch -p2 -i "${PATCH_1}"

  download_file "https://github.com/nihui/llvm-project/commit/${PATCH_2}" "${PATCH_2}"
  patch -p2 -i "${PATCH_2}"

  touch "${marker}"
  popd >/dev/null
}

build_openmp_arm64() {
  echo "[build] openmp arm64"
  cmake -S "${OPENMP_SRC_DIR}" -B "${OPENMP_BUILD_DIR}" \
    -DCMAKE_TOOLCHAIN_FILE="${SCRIPT_DIR}/toolchains/ios.toolchain.cmake" \
    -DDEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}" \
    -DENABLE_BITCODE="${ENABLE_BITCODE}" \
    -DENABLE_ARC="${ENABLE_ARC}" \
    -DENABLE_VISIBILITY="${ENABLE_VISIBILITY}" \
    -DCMAKE_INSTALL_PREFIX="${OPENMP_INSTALL_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLIBOMP_ENABLE_SHARED=OFF \
    -DLIBOMP_OMPT_SUPPORT=OFF \
    -DLIBOMP_USE_HWLOC=OFF \
    -DPLATFORM=OS64 \
    -DARCHS=arm64

  cmake --build "${OPENMP_BUILD_DIR}" -j "$(num_jobs)"
  cmake --build "${OPENMP_BUILD_DIR}" --target install
}

normalize_openmp_artifacts() {
  local header_candidate=""
  local lib_candidate=""

  if [[ -f "${OPENMP_INSTALL_DIR}/include/omp.h" ]]; then
    header_candidate="${OPENMP_INSTALL_DIR}/include"
  elif [[ -f "${OPENMP_BUILD_DIR}/runtime/src/omp.h" ]]; then
    header_candidate="${OPENMP_BUILD_DIR}/runtime/src"
  elif [[ -f "${OPENMP_SRC_DIR}/runtime/src/omp.h" ]]; then
    header_candidate="${OPENMP_SRC_DIR}/runtime/src"
  fi

  if [[ -f "${OPENMP_INSTALL_DIR}/lib/libomp.a" ]]; then
    lib_candidate="${OPENMP_INSTALL_DIR}/lib/libomp.a"
  elif [[ -f "${OPENMP_BUILD_DIR}/runtime/src/libomp.a" ]]; then
    lib_candidate="${OPENMP_BUILD_DIR}/runtime/src/libomp.a"
  elif [[ -f "${OPENMP_BUILD_DIR}/runtime/src/libiomp5.a" ]]; then
    lib_candidate="${OPENMP_BUILD_DIR}/runtime/src/libiomp5.a"
  elif [[ -f "${OPENMP_BUILD_DIR}/runtime/src/libgomp.a" ]]; then
    lib_candidate="${OPENMP_BUILD_DIR}/runtime/src/libgomp.a"
  fi

  if [[ -z "${header_candidate}" || -z "${lib_candidate}" ]]; then
    echo "failed to locate OpenMP headers or library"
    echo "header_candidate=${header_candidate}"
    echo "lib_candidate=${lib_candidate}"
    exit 1
  fi

  ensure_dir "${OPENMP_INSTALL_DIR}/include"
  ensure_dir "${OPENMP_INSTALL_DIR}/lib"

  if [[ "${header_candidate}/omp.h" != "${OPENMP_INSTALL_DIR}/include/omp.h" ]]; then
    cp -f "${header_candidate}/omp.h" "${OPENMP_INSTALL_DIR}/include/omp.h"
  fi
  if [[ -f "${header_candidate}/ompx.h" ]]; then
    if [[ "${header_candidate}/ompx.h" != "${OPENMP_INSTALL_DIR}/include/ompx.h" ]]; then
      cp -f "${header_candidate}/ompx.h" "${OPENMP_INSTALL_DIR}/include/ompx.h"
    fi
  fi
  if [[ "${lib_candidate}" != "${OPENMP_INSTALL_DIR}/lib/libomp.a" ]]; then
    cp -f "${lib_candidate}" "${OPENMP_INSTALL_DIR}/lib/libomp.a"
  fi

  OPENMP_HEADER_DIR="${OPENMP_INSTALL_DIR}/include"
  OPENMP_LIBRARY_FILE="${OPENMP_INSTALL_DIR}/lib/libomp.a"
}

build_ncnn_arm64() {
  echo "[build] ncnn arm64 (VULKAN=${VULKAN})"

  ensure_submodules

  cmake -S "${SCRIPT_DIR}" -B "${NCNN_BUILD_DIR}" \
    -DCMAKE_TOOLCHAIN_FILE="${SCRIPT_DIR}/toolchains/ios.toolchain.cmake" \
    -DDEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}" \
    -DENABLE_BITCODE="${ENABLE_BITCODE}" \
    -DENABLE_ARC="${ENABLE_ARC}" \
    -DENABLE_VISIBILITY="${ENABLE_VISIBILITY}" \
    -DCMAKE_INSTALL_PREFIX="${NCNN_INSTALL_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DPLATFORM=OS64 \
    -DARCHS=arm64 \
    -DOpenMP_C_FLAGS="-Xclang -fopenmp -I${OPENMP_HEADER_DIR}" \
    -DOpenMP_CXX_FLAGS="-Xclang -fopenmp -I${OPENMP_HEADER_DIR}" \
    -DOpenMP_C_LIB_NAMES=libomp \
    -DOpenMP_CXX_LIB_NAMES=libomp \
    -DOpenMP_libomp_LIBRARY="${OPENMP_LIBRARY_FILE}" \
    -DNCNN_VULKAN="${VULKAN}"

  cmake --build "${NCNN_BUILD_DIR}" -j "$(num_jobs)"
  cmake --build "${NCNN_BUILD_DIR}" --target install
}

init_framework_layout() {
  local framework_path="$1"
  local binary_name="$2"

  rm -rf "${framework_path}"
  mkdir -p "${framework_path}/Versions/A/Headers"
  mkdir -p "${framework_path}/Versions/A/Resources"
  ln -s A "${framework_path}/Versions/Current"
  ln -s Versions/Current/Headers "${framework_path}/Headers"
  ln -s Versions/Current/Resources "${framework_path}/Resources"
  ln -s Versions/Current/${binary_name} "${framework_path}/${binary_name}"
}

package_frameworks() {
  echo "[package] frameworks"
  ensure_dir "${PACKAGE_DIR}"

  local openmp_framework="${PACKAGE_DIR}/openmp.framework"
  local ncnn_framework="${PACKAGE_DIR}/ncnn.framework"
  local glslang_framework="${PACKAGE_DIR}/glslang.framework"

  init_framework_layout "${openmp_framework}" "openmp"
  cp "${OPENMP_INSTALL_DIR}/lib/libomp.a" "${openmp_framework}/Versions/A/openmp"
  cp -a "${OPENMP_INSTALL_DIR}/include/"* "${openmp_framework}/Versions/A/Headers/"
  sed -e 's/__NAME__/openmp/g' \
      -e 's/__IDENTIFIER__/org.llvm.openmp/g' \
      -e 's/__VERSION__/18.1/g' \
      "${SCRIPT_DIR}/Info.plist" > "${openmp_framework}/Versions/A/Resources/Info.plist"

  init_framework_layout "${ncnn_framework}" "ncnn"
  cp "${NCNN_INSTALL_DIR}/lib/libncnn.a" "${ncnn_framework}/Versions/A/ncnn"
  cp -a "${NCNN_INSTALL_DIR}/include/"* "${ncnn_framework}/Versions/A/Headers/"
  sed -e 's/__NAME__/ncnn/g' \
      -e 's/__IDENTIFIER__/com.tencent.ncnn/g' \
      -e 's/__VERSION__/1.0/g' \
      "${SCRIPT_DIR}/Info.plist" > "${ncnn_framework}/Versions/A/Resources/Info.plist"

  if [[ "${VULKAN}" == "ON" ]]; then
    init_framework_layout "${glslang_framework}" "glslang"
    libtool -static \
      "${NCNN_INSTALL_DIR}/lib/libglslang.a" \
      "${NCNN_INSTALL_DIR}/lib/libSPIRV.a" \
      -o "${NCNN_INSTALL_DIR}/lib/libglslang_combined.a"
    cp "${NCNN_INSTALL_DIR}/lib/libglslang_combined.a" "${glslang_framework}/Versions/A/glslang"
    cp -a "${NCNN_INSTALL_DIR}/include/glslang" "${glslang_framework}/Versions/A/Headers/"
    sed -e 's/__NAME__/glslang/g' \
        -e 's/__IDENTIFIER__/org.khronos.glslang/g' \
        -e 's/__VERSION__/1.0/g' \
        "${SCRIPT_DIR}/Info.plist" > "${glslang_framework}/Versions/A/Resources/Info.plist"
  fi
}

zip_package() {
  pushd "${PACKAGE_DIR}" >/dev/null
  local zip_name="ncnn-ios-arm64-local.zip"
  if [[ "${VULKAN}" == "ON" ]]; then
    zip_name="ncnn-ios-arm64-vulkan-local.zip"
    rm -f "${zip_name}"
    zip -9 -y -r "${zip_name}" openmp.framework glslang.framework ncnn.framework >/dev/null
  else
    rm -f "${zip_name}"
    zip -9 -y -r "${zip_name}" openmp.framework ncnn.framework >/dev/null
  fi
  popd >/dev/null
}

print_summary() {
  echo ""
  echo "Done."
  echo "Build root: ${BUILD_ROOT}"
  echo "OpenMP lib: ${OPENMP_INSTALL_DIR}/lib/libomp.a"
  echo "NCNN lib:   ${NCNN_INSTALL_DIR}/lib/libncnn.a"
  echo "Frameworks: ${PACKAGE_DIR}"

  xcrun lipo -info "${PACKAGE_DIR}/openmp.framework/openmp"
  xcrun lipo -info "${PACKAGE_DIR}/ncnn.framework/ncnn"
  if [[ "${VULKAN}" == "ON" ]]; then
    xcrun lipo -info "${PACKAGE_DIR}/glslang.framework/glslang"
    echo "Zip: ${PACKAGE_DIR}/ncnn-ios-arm64-vulkan-local.zip"
  else
    echo "Zip: ${PACKAGE_DIR}/ncnn-ios-arm64-local.zip"
  fi
}

main() {
  require_tools

  if [[ "${CLEAN}" -eq 1 ]]; then
    echo "[clean] ${BUILD_ROOT}"
    rm -rf "${BUILD_ROOT}"
  fi

  prepare_openmp_source
  apply_openmp_patches
  build_openmp_arm64
  normalize_openmp_artifacts
  build_ncnn_arm64
  package_frameworks
  zip_package
  print_summary
}

main
