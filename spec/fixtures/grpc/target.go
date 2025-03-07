package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"time"
	"strings"

	pb "grpc/targetservice"

	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/timestamppb"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const (
	port = "localhost:15010"
)

type server struct {
	pb.UnimplementedBouncerServer
}

func (s *server) SayHello(ctx context.Context, in *pb.HelloRequest) (*pb.HelloResponse, error) {
	return &pb.HelloResponse{
		Reply:       fmt.Sprintf("hello %s", in.GetGreeting()),
		BooleanTest: in.GetBooleanTest(),
	}, nil
}

func (s *server) BounceIt(ctx context.Context, in *pb.BallIn) (*pb.BallOut, error) {
	w := in.GetWhen().AsTime()
	now := in.GetNow().AsTime()
	ago := now.Sub(w)

	reply := fmt.Sprintf("hello %s", in.GetMessage())
	time_message := fmt.Sprintf("%s was %v ago", w.Format(time.RFC3339), ago.Truncate(time.Second))

	return &pb.BallOut{
		Reply:       reply,
		TimeMessage: time_message,
		Now:         timestamppb.New(now),
	}, nil
}

func (s *server) GrowTail(ctx context.Context, in *pb.Body) (*pb.Body, error) {
	in.Tail.Count += 1

	return in, nil
}

func (s *server) Echo(ctx context.Context, in *pb.EchoMsg) (*pb.EchoMsg, error) {
	return in, nil
}

func (s *server) EchoHeaders(ctx context.Context, in *pb.Void) (*pb.Headers, error) {
	md, ok := metadata.FromIncomingContext(ctx)
	if !ok {
		return nil, status.Errorf(codes.DataLoss, "UnaryEcho: failed to get metadata")
	}
	headers := &pb.Headers{}
	var headersMap = make(map[string]string, len(md))
	for k, v := range md {
		headersMap[k] = strings.Join(v, ", ")
	}
	headers.Headers = headersMap
	return headers, nil
}

func main() {
	lis, err := net.Listen("tcp", port)
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}
	s := grpc.NewServer()
	pb.RegisterBouncerServer(s, &server{})
	log.Printf("server listening at %v", lis.Addr())
	if err := s.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
