param([switch]$runSysprep=$false)

write-output "Sysprep Script Run, parameter 'runSysprep': $runSysprep"

if ($runSysprep) {
  write-output "`nDeleting C:\Windows\Panther directory..."
  Remove-Item C:\windows\Panther\test -Recurse -Force
  
  write-output "`nStarting Sysprep..."
  Start-Process -FilePath C:\Windows\System32\Sysprep\Sysprep.exe -ArgumentList '/generalize /oobe /shutdown /quiet'
}
else {
  write-output "`nSkipping Sysprep..."
}
