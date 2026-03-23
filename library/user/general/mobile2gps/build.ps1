# Build for MIPS 24KEc soft-float (OpenWRT)
$env:GOOS = "linux"
$env:GOARCH = "mipsle"
$env:GOMIPS = "softfloat"

go build -ldflags="-s -w" -o mobile2gps .

Write-Host "Built: mobile2gps (linux/mipsle softfloat)"
