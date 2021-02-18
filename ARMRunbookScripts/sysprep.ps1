param([switch]$runSysprep=$false)

write-output "Sysprep Script Run, parameter 'runSysprep': $runSysprep"

If ($runSysprep) {
  If (Test-Path -Path "C:\windows\Panther") {
    Write-output "`nDeleting C:\Windows\Panther directory..."
    Remove-Item C:\windows\Panther -Recurse -Force
  }
  Write-output "`nStarting Sysprep..."
  Start-Process -FilePath C:\Windows\System32\Sysprep\Sysprep.exe -ArgumentList '/generalize /oobe /shutdown /mode:vm' -Wait
}
Else {
  write-output "`nSkipping Sysprep..."
}
