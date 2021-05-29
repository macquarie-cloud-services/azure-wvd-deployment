# Run sysprep in vm mode

If (Test-Path -Path "C:\windows\Panther") {
  Write-output "`nDeleting C:\Windows\Panther directory..."
  Remove-Item C:\windows\Panther -Recurse -Force
}
Write-output "`nStarting Sysprep..."
Start-Process -FilePath C:\Windows\System32\Sysprep\Sysprep.exe -ArgumentList '/generalize /oobe /shutdown /mode:vm'
