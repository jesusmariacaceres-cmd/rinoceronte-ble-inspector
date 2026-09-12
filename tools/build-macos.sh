#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodebuild >/dev/null
command -v protoc >/dev/null
command -v xcodegen >/dev/null
# Pin generator and runtime to the same reviewed release.
if [ ! -d .build-tools/swift-protobuf ]; then
  mkdir -p .build-tools
  git clone --depth 1 --branch 1.28.2 https://github.com/apple/swift-protobuf.git .build-tools/swift-protobuf
fi
swift build --package-path .build-tools/swift-protobuf -c release --product protoc-gen-swift
proto_dir=Vendor/TeslaBLEKeyKit/Sources/TeslaBLEKeyKitCore/Protos
generated_dir=Vendor/TeslaBLEKeyKit/Sources/TeslaBLEKeyKitCore/Generated
mkdir -p "$generated_dir"
protoc -I "$proto_dir" --plugin=protoc-gen-swift=.build-tools/swift-protobuf/.build/release/protoc-gen-swift --swift_out="$generated_dir" --swift_opt=Visibility=Public "$proto_dir"/*.proto
swift test --package-path Vendor/TeslaBLEKeyKit
xcodegen generate
xcodebuild -project RinoceronteInspector.xcodeproj -scheme RinoceronteInspector -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
mkdir -p build/package/Payload
cp -R build/Build/Products/Release-iphoneos/RinoceronteInspector.app build/package/Payload/
(cd build/package && /usr/bin/zip -qr ../RinoceronteInspector-unsigned.ipa Payload)
/usr/bin/unzip -t build/RinoceronteInspector-unsigned.ipa
xcodebuild -version > build/toolchain.txt
protoc --version >> build/toolchain.txt
shasum -a 256 build/RinoceronteInspector-unsigned.ipa > build/SHA256SUMS.txt
