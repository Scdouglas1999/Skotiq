$source = "C:\Users\scdou\Documents\Skotiq2\apps\desktop\build\windows\x64\runner\Release"
$dest = "\\192.168.1.59\Skotiq"

Write-Host "Copying from: $source"
Write-Host "Copying to: $dest"

# Copy all files
Copy-Item -Path "$source\*" -Destination $dest -Recurse -Force

Write-Host "Done!"
Get-Item "$dest\data\app.so" | Select-Object LastWriteTime, Length
