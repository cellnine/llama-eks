FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/gateway .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/gateway /usr/bin/gateway
USER 65534:65534
ENTRYPOINT ["/usr/bin/gateway"]
