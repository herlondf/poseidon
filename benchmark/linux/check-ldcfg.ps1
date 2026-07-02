Get-ChildItem 'D:\Emb\bin' -File | Where-Object { $_.Name -match 'ld|link|\.cfg|\.conf' } | Select-Object Name | Sort-Object Name
