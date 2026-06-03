function Get-DockerCommand {
  $dockerBin = "C:\Program Files\Docker\Docker\resources\bin"
  if ((Test-Path $dockerBin) -and ($env:PATH -notlike "*$dockerBin*")) {
    $env:PATH = "$dockerBin;$env:PATH"
  }

  $cmd = Get-Command docker -ErrorAction SilentlyContinue
  if ($cmd) {
    return $cmd.Source
  }

  $defaultPath = Join-Path $dockerBin "docker.exe"
  if (Test-Path $defaultPath) {
    return $defaultPath
  }

  throw "docker.exe was not found. Start Docker Desktop and ensure Docker is installed."
}

function Invoke-Docker {
  $docker = Get-DockerCommand
  & $docker @args
}
