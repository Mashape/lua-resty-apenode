ALL= targetservice/targetservice.pb.go targetservice/targetservice_grpc.pb.go target

all: $(ALL)

.PHONY: go

clean:
	rm -rf $(ALL)

go:
	go mod tidy && go mod download all

target: go targetservice/targetservice.pb.go targetservice/targetservice_grpc.pb.go target.go
	go build -o $@

targetservice/targetservice.pb.go: proto/targetservice.proto
	protoc -I proto/ --go_out=. --go-grpc_out=. proto/targetservice.proto

targetservice/targetservice_grpc.pb.go: proto/targetservice.proto
	protoc -I proto/ --go_out=. --go-grpc_out=. proto/targetservice.proto
