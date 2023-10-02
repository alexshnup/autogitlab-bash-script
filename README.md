# autogitlab-bash-script

The gitlab_automation_test.sh script does the following:
- Run a Docker container with Gitlab-CE-Server latest version
- Run a Docker container with Gitlab-Runner
- creates a user (using Ruby script)
- gets a token for the API
- receives a token for the runner (using Ruby script)
- registers the runner (using docker exec)
- pushes two repositories located in the frontend and frontend_build directories, which should be one level higher
- adds several CI/CD variables to the project frontend-build. (using Gitlab API)
- adds a tag for launching CI/CD to the project frontend-build. (using Gitlab API)

# Dependencies 
- docker
- curl
- jq

### Example directory tree
```
├── frontend
├── frontend_build
└── autogitlab-bash-script
    ├── gitlab_automation_test.sh
