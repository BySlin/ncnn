#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OPENMP_VERSION="${OPENMP_VERSION:-18.1.2}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-15.0}"
ENABLE_BITCODE="${ENABLE_BITCODE:-OFF}"
ENABLE_ARC="${ENABLE_ARC:-OFF}"
ENABLE_VISIBILITY="${ENABLE_VISIBILITY:-OFF}"
VULKAN="${NCNN_VULKAN:-ON}"

BUILD_ROOT="${SCRIPT_DIR}/build_ios"
DOWNLOAD_DIR="${BUILD_ROOT}/downloads"
OPENMP_SRC_DIR="${BUILD_ROOT}/openmp-${OPENMP_VERSION}.src"
CMAKE_SRC_DIR="${BUILD_ROOT}/cmake-${OPENMP_VERSION}.src"
PACKAGE_DIR_IOS="${BUILD_ROOT}/package-ios-arm64"
PACKAGE_DIR_SIMULATOR="${BUILD_ROOT}/package-ios-simulator"
PACKAGE_DIR_XCFRAMEWORK="${BUILD_ROOT}/package-xcframework"

PATCH_1="ef8c35bcf5d9cfdb0764ffde6a63c04ec715bc37.patch"
PATCH_2="5c12711f9a21f41bea70566bf15a4026804d6b20.patch"

# A slice is <sdk>-<arch>: ios-arm64, ios-simulator-arm64, ios-simulator-x86_64
DEVICE_SLICE="ios-arm64"
SIMULATOR_ARCHS="${SIMULATOR_ARCHS:-arm64}"
SIMULATOR_SLICES=()

SIMULATOR=1
CLEAN=0

usage() {
  cat <<EOF
Usage: ./build_ios.sh [options]

Options:
  --vulkan ON|OFF   Build ncnn with Vulkan (default: ON)
  --no-simulator    Build the device slice only, skip simulator and xcframework
  --clean           Clean ${BUILD_ROOT} build outputs before building
  -h, --help        Show this help

Environment overrides:
  OPENMP_VERSION
  IOS_DEPLOYMENT_TARGET
  SIMULATOR_ARCHS   Simulator archs to build, arm64 and/or x86_64 (default: "arm64")
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
    --no-simulator)
      SIMULATOR=0
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

if [[ "${SIMULATOR}" -eq 1 ]]; then
  for arch in ${SIMULATOR_ARCHS}; do
    if [[ "${arch}" != "arm64" && "${arch}" != "x86_64" ]]; then
      echo "SIMULATOR_ARCHS only supports arm64 and x86_64, got: ${arch}"
      exit 1
    fi
    SIMULATOR_SLICES+=("ios-simulator-${arch}")
  done
  if [[ "${#SIMULATOR_SLICES[@]}" -eq 0 ]]; then
    echo "SIMULATOR_ARCHS is empty; use --no-simulator to skip the simulator build"
    exit 1
  fi
fi

slice_platform() {
  case "$1" in
    ios-arm64) echo "OS64" ;;
    ios-simulator-arm64) echo "SIMULATORARM64" ;;
    ios-simulator-x86_64) echo "SIMULATOR64" ;;
    *) echo "unknown slice: $1" >&2; exit 1 ;;
  esac
}

slice_arch() {
  echo "${1##*-}"
}

openmp_build_dir() {
  echo "${OPENMP_SRC_DIR}/build-$1"
}

openmp_install_dir() {
  echo "$(openmp_build_dir "$1")/install"
}

ncnn_build_dir() {
  echo "${BUILD_ROOT}/ncnn-build-$1"
}

ncnn_install_dir() {
  echo "${BUILD_ROOT}/install-$1"
}

require_tools() {
  local tools=(
    cmake
    curl
    tar
    patch
    git
    libtool
    xcrun
    xcodebuild
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

build_openmp() {
  local slice="$1"
  local build_dir install_dir
  build_dir="$(openmp_build_dir "${slice}")"
  install_dir="$(openmp_install_dir "${slice}")"

  echo "[build] openmp ${slice}"
  cmake -S "${OPENMP_SRC_DIR}" -B "${build_dir}" \
    -DCMAKE_TOOLCHAIN_FILE="${SCRIPT_DIR}/toolchains/ios.toolchain.cmake" \
    -DDEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}" \
    -DENABLE_BITCODE="${ENABLE_BITCODE}" \
    -DENABLE_ARC="${ENABLE_ARC}" \
    -DENABLE_VISIBILITY="${ENABLE_VISIBILITY}" \
    -DCMAKE_INSTALL_PREFIX="${install_dir}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLIBOMP_ENABLE_SHARED=OFF \
    -DLIBOMP_OMPT_SUPPORT=OFF \
    -DLIBOMP_USE_HWLOC=OFF \
    -DPLATFORM="$(slice_platform "${slice}")" \
    -DARCHS="$(slice_arch "${slice}")"

  cmake --build "${build_dir}" -j "$(num_jobs)"
  cmake --build "${build_dir}" --target install
}

normalize_openmp_artifacts() {
  local slice="$1"
  local build_dir install_dir
  build_dir="$(openmp_build_dir "${slice}")"
  install_dir="$(openmp_install_dir "${slice}")"

  local header_candidate=""
  local lib_candidate=""

  if [[ -f "${install_dir}/include/omp.h" ]]; then
    header_candidate="${install_dir}/include"
  elif [[ -f "${build_dir}/runtime/src/omp.h" ]]; then
    header_candidate="${build_dir}/runtime/src"
  elif [[ -f "${OPENMP_SRC_DIR}/runtime/src/omp.h" ]]; then
    header_candidate="${OPENMP_SRC_DIR}/runtime/src"
  fi

  if [[ -f "${install_dir}/lib/libomp.a" ]]; then
    lib_candidate="${install_dir}/lib/libomp.a"
  elif [[ -f "${build_dir}/runtime/src/libomp.a" ]]; then
    lib_candidate="${build_dir}/runtime/src/libomp.a"
  elif [[ -f "${build_dir}/runtime/src/libiomp5.a" ]]; then
    lib_candidate="${build_dir}/runtime/src/libiomp5.a"
  elif [[ -f "${build_dir}/runtime/src/libgomp.a" ]]; then
    lib_candidate="${build_dir}/runtime/src/libgomp.a"
  fi

  if [[ -z "${header_candidate}" || -z "${lib_candidate}" ]]; then
    echo "failed to locate OpenMP headers or library for ${slice}"
    echo "header_candidate=${header_candidate}"
    echo "lib_candidate=${lib_candidate}"
    exit 1
  fi

  ensure_dir "${install_dir}/include"
  ensure_dir "${install_dir}/lib"

  if [[ "${header_candidate}/omp.h" != "${install_dir}/include/omp.h" ]]; then
    cp -f "${header_candidate}/omp.h" "${install_dir}/include/omp.h"
  fi
  if [[ -f "${header_candidate}/ompx.h" ]]; then
    if [[ "${header_candidate}/ompx.h" != "${install_dir}/include/ompx.h" ]]; then
      cp -f "${header_candidate}/ompx.h" "${install_dir}/include/ompx.h"
    fi
  fi
  if [[ "${lib_candidate}" != "${install_dir}/lib/libomp.a" ]]; then
    cp -f "${lib_candidate}" "${install_dir}/lib/libomp.a"
  fi
}

build_ncnn() {
  local slice="$1"
  local build_dir install_dir openmp_dir
  build_dir="$(ncnn_build_dir "${slice}")"
  install_dir="$(ncnn_install_dir "${slice}")"
  openmp_dir="$(openmp_install_dir "${slice}")"

  echo "[build] ncnn ${slice} (VULKAN=${VULKAN})"

  ensure_submodules

  cmake -S "${SCRIPT_DIR}" -B "${build_dir}" \
    -DCMAKE_TOOLCHAIN_FILE="${SCRIPT_DIR}/toolchains/ios.toolchain.cmake" \
    -DDEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}" \
    -DENABLE_BITCODE="${ENABLE_BITCODE}" \
    -DENABLE_ARC="${ENABLE_ARC}" \
    -DENABLE_VISIBILITY="${ENABLE_VISIBILITY}" \
    -DCMAKE_INSTALL_PREFIX="${install_dir}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DPLATFORM="$(slice_platform "${slice}")" \
    -DARCHS="$(slice_arch "${slice}")" \
    -DOpenMP_C_FLAGS="-Xclang -fopenmp -I${openmp_dir}/include" \
    -DOpenMP_CXX_FLAGS="-Xclang -fopenmp -I${openmp_dir}/include" \
    -DOpenMP_C_LIB_NAMES=libomp \
    -DOpenMP_CXX_LIB_NAMES=libomp \
    -DOpenMP_libomp_LIBRARY="${openmp_dir}/lib/libomp.a" \
    -DNCNN_VULKAN="${VULKAN}"

  cmake --build "${build_dir}" -j "$(num_jobs)"
  cmake --build "${build_dir}" --target install
}

build_slice() {
  local slice="$1"
  build_openmp "${slice}"
  normalize_openmp_artifacts "${slice}"
  build_ncnn "${slice}"
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

# merge the same static library of every slice into one (fat) file
merge_libraries() {
  local output="$1"
  shift

  if [[ $# -eq 1 ]]; then
    cp "$1" "${output}"
  else
    xcrun lipo -create "$@" -o "${output}"
  fi
}

# package_frameworks <package dir> <slice>...
# headers are taken from the first slice
package_frameworks() {
  local package_dir="$1"
  shift
  local slices=("$@")
  local first_slice="${slices[0]}"

  echo "[package] frameworks ${slices[*]}"
  ensure_dir "${package_dir}"

  local openmp_framework="${package_dir}/openmp.framework"
  local ncnn_framework="${package_dir}/ncnn.framework"
  local glslang_framework="${package_dir}/glslang.framework"

  local slice
  local openmp_libs=()
  local ncnn_libs=()
  local glslang_libs=()
  for slice in "${slices[@]}"; do
    openmp_libs+=("$(openmp_install_dir "${slice}")/lib/libomp.a")
    ncnn_libs+=("$(ncnn_install_dir "${slice}")/lib/libncnn.a")
    if [[ "${VULKAN}" == "ON" ]]; then
      libtool -static \
        "$(ncnn_install_dir "${slice}")/lib/libglslang.a" \
        "$(ncnn_install_dir "${slice}")/lib/libSPIRV.a" \
        -o "$(ncnn_install_dir "${slice}")/lib/libglslang_combined.a"
      glslang_libs+=("$(ncnn_install_dir "${slice}")/lib/libglslang_combined.a")
    fi
  done

  init_framework_layout "${openmp_framework}" "openmp"
  merge_libraries "${openmp_framework}/Versions/A/openmp" "${openmp_libs[@]}"
  cp -a "$(openmp_install_dir "${first_slice}")/include/"* "${openmp_framework}/Versions/A/Headers/"
  sed -e 's/__NAME__/openmp/g' \
      -e 's/__IDENTIFIER__/org.llvm.openmp/g' \
      -e 's/__VERSION__/18.1/g' \
      "${SCRIPT_DIR}/Info.plist" > "${openmp_framework}/Versions/A/Resources/Info.plist"

  init_framework_layout "${ncnn_framework}" "ncnn"
  merge_libraries "${ncnn_framework}/Versions/A/ncnn" "${ncnn_libs[@]}"
  cp -a "$(ncnn_install_dir "${first_slice}")/include/"* "${ncnn_framework}/Versions/A/Headers/"
  sed -e 's/__NAME__/ncnn/g' \
      -e 's/__IDENTIFIER__/com.tencent.ncnn/g' \
      -e 's/__VERSION__/1.0/g' \
      "${SCRIPT_DIR}/Info.plist" > "${ncnn_framework}/Versions/A/Resources/Info.plist"

  if [[ "${VULKAN}" == "ON" ]]; then
    init_framework_layout "${glslang_framework}" "glslang"
    merge_libraries "${glslang_framework}/Versions/A/glslang" "${glslang_libs[@]}"
    cp -a "$(ncnn_install_dir "${first_slice}")/include/glslang" "${glslang_framework}/Versions/A/Headers/"
    sed -e 's/__NAME__/glslang/g' \
        -e 's/__IDENTIFIER__/org.khronos.glslang/g' \
        -e 's/__VERSION__/1.0/g' \
        "${SCRIPT_DIR}/Info.plist" > "${glslang_framework}/Versions/A/Resources/Info.plist"
  fi
}

framework_names() {
  if [[ "${VULKAN}" == "ON" ]]; then
    echo "openmp glslang ncnn"
  else
    echo "openmp ncnn"
  fi
}

package_xcframeworks() {
  echo "[package] xcframeworks"
  ensure_dir "${PACKAGE_DIR_XCFRAMEWORK}"

  local name
  for name in $(framework_names); do
    rm -rf "${PACKAGE_DIR_XCFRAMEWORK}/${name}.xcframework"
    xcodebuild -create-xcframework \
      -framework "${PACKAGE_DIR_IOS}/${name}.framework" \
      -framework "${PACKAGE_DIR_SIMULATOR}/${name}.framework" \
      -output "${PACKAGE_DIR_XCFRAMEWORK}/${name}.xcframework"
  done
}

# zip_package <package dir> <zip name without suffix> <bundle suffix>
zip_package() {
  local package_dir="$1"
  local zip_name="$2"
  local suffix="$3"

  if [[ "${VULKAN}" == "ON" ]]; then
    zip_name="${zip_name}-vulkan"
  fi
  zip_name="${zip_name}-local.zip"

  local name
  local bundles=()
  for name in $(framework_names); do
    bundles+=("${name}.${suffix}")
  done

  pushd "${package_dir}" >/dev/null
  rm -f "${zip_name}"
  zip -9 -y -r "${zip_name}" "${bundles[@]}" >/dev/null
  popd >/dev/null

  echo "Zip: ${package_dir}/${zip_name}"
}

print_summary() {
  echo ""
  echo "Done."
  echo "Build root: ${BUILD_ROOT}"

  local name
  echo "Frameworks (ios): ${PACKAGE_DIR_IOS}"
  for name in $(framework_names); do
    xcrun lipo -info "${PACKAGE_DIR_IOS}/${name}.framework/${name}"
  done

  if [[ "${SIMULATOR}" -eq 1 ]]; then
    echo "Frameworks (ios-simulator): ${PACKAGE_DIR_SIMULATOR}"
    for name in $(framework_names); do
      xcrun lipo -info "${PACKAGE_DIR_SIMULATOR}/${name}.framework/${name}"
    done
    echo "XCFrameworks: ${PACKAGE_DIR_XCFRAMEWORK}"
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

  build_slice "${DEVICE_SLICE}"
  package_frameworks "${PACKAGE_DIR_IOS}" "${DEVICE_SLICE}"

  if [[ "${SIMULATOR}" -eq 1 ]]; then
    local slice
    for slice in "${SIMULATOR_SLICES[@]}"; do
      build_slice "${slice}"
    done
    package_frameworks "${PACKAGE_DIR_SIMULATOR}" "${SIMULATOR_SLICES[@]}"
    package_xcframeworks
  fi

  print_summary
  zip_package "${PACKAGE_DIR_IOS}" "ncnn-ios-arm64" "framework"
  if [[ "${SIMULATOR}" -eq 1 ]]; then
    zip_package "${PACKAGE_DIR_SIMULATOR}" "ncnn-ios-simulator" "framework"
    zip_package "${PACKAGE_DIR_XCFRAMEWORK}" "ncnn-ios" "xcframework"
  fi
}

main
