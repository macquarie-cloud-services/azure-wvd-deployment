param([switch]$runSysprep=$false)

write-output "Sysprep Script Run, parameter 'runSysprep': $runSysprep"

if ($runSysprep) {
  write-output "starting Sysprep"
  Start-Process -FilePath C:\Windows\System32\Sysprep\Sysprep.exe -ArgumentList '/generalize /oobe /shutdown /quiet'
  write-output "started Sysprep"
}
else {
  write-output "skipping Sysprep"
}
