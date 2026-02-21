```bash
az bicep build --file .\infra\management-groups.bicep 
az deployment mg what-if --management-group-id testmg --location westus --name rollout01 --template-uri https://myresource/azuredeploy.json --parameters @myparameters.json --no-pretty-print
```