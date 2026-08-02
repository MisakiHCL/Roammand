module github.com/MisakiHCL/roammand/services/signaling

go 1.26.0

toolchain go1.26.5

require (
	github.com/MisakiHCL/roammand/gen/go v0.0.0
	github.com/coder/websocket v1.8.15
	google.golang.org/protobuf v1.36.11
)

replace github.com/MisakiHCL/roammand/gen/go => ../../gen/go
