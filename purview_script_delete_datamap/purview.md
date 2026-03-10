## Steps
** After saving the file as .ps1 in azure cli portal
** ls or pwd, and run below command.
** **Note** you are to pass the values of the TenantId, ClientId etc in the terminal
** this `-DiscoverOnly` will first print the asset to be deleted into a `-GuidsFile` value that you specify - so you can preview it. 

```ps1
.\purview-discover-export-delete.ps1 `
  -TenantId "<tenant-guid>" `
  -ClientId "<app-id>" `
  -ClientSecret "<secret>" `
  -PurviewAccountName "<purview-account>" `
  -CollectionId "<collectionNameOrId>" `
  -DiscoverOnly `
  -GuidsFile ".\to_delete_guids.txt"

```
** We can also only `Delete only assets whose qualifiedName begins with mssql://myserver...`

```ps
.\purview-discover-export-delete.ps1 `
  -TenantId "<tenant-guid>" `
  -ClientId "<app-id>" `
  -ClientSecret "<secret>" `
  -PurviewAccountName "<purview-account>" `
  -CollectionId "<collectionNameOrId>" `
  -QualifiedNamePrefix "mssql://myserver.database.windows.net" `
  -GuidsFile ".\sql_assets_guids.txt"
```
** Then, run with `-DeleteOnly` then deletes it.

```ps1
.\purview-discover-export-delete.ps1 `
  -TenantId "<tenant-guid>" `
  -ClientId "<app-id>" `
  -ClientSecret "<secret>" `
  -PurviewAccountName "<purview-account>" `
  -CollectionId "<collectionNameOrId>" `
  -DeleteOnly `
  -GuidsFile ".\to_delete_guids.txt"
```