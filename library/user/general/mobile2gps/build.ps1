# Build for MIPS 24KEc soft-float (OpenWRT)
$env:GOOS = "linux"
$env:GOARCH = "mipsle"
$env:GOMIPS = "softfloat"

go build -ldflags="-s -w" -o Mobile2GPS .

Write-Host "Built: Mobile2GPS (linux/mipsle softfloat)"
