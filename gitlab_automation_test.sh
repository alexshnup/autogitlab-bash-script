#!/bin/bash

GITLAB_URL="http://127.0.0.1"
GITLAB_HOSTNAME="gitlab-server"
GITLAB_DOCKER_NETWORK_NAME="bridge"
GITLAB_WEB_EXPOSE_PORT=80
GITLAB_SSH_EXPOSE_PORT=222
INITIAL_ROOT_PASSWORD="GHJ#hjhd@"
NEW_USER_NAME=devops
NEW_USER_PASS="GHJ#hjhd@"
NEW_USER_EMAIL=devops@example.com
NEW_USER_TOKEN=abcd1234
PROJECT_NAME=frontend-build
GITLAB_PATH_SRC_PROJECT="devops/frontend"
CI_REGISTRY=registry
CI_REGISTRY_LOCAL=true
CI_REGISTRY_USER=testuser
CI_REGISTRY_PASSWORD=testpassword

# DNSHOSTREC="127.0.0.1 $GITLAB_HOSTNAME"; sudo sh -c "if ! grep -q '$DNSHOSTREC' /etc/hosts; then echo '$DNSHOSTREC' >> /etc/hosts; fi"


create_gitlab_container() {
    echo "Creating GitLab container..."
    # Check if the network exists
    network_exists=$(docker network ls | grep -c "$GITLAB_DOCKER_NETWORK_NAME")

    # If the network doesn't exist, create it
    if [[ $network_exists -eq 0 ]]; then
      docker network create $GITLAB_DOCKER_NETWORK_NAME
    fi


    if  curl -s "http://$GITLAB_HOSTNAME/users/sign_in" | grep -q 'GitLab'; then
      echo "Found Gitlab"
    else
      echo "Gitlab NOT Found, will be RUN"
        # # Start GitLab in Docker
        docker run --detach \
        --network $GITLAB_DOCKER_NETWORK_NAME \
        --hostname $GITLAB_HOSTNAME \
        --publish $GITLAB_WEB_EXPOSE_PORT:80 --publish $GITLAB_SSH_EXPOSE_PORT:22 \
        --name $GITLAB_HOSTNAME \
        -e GITLAB_OMNIBUS_CONFIG="gitlab_rails['initial_root_password'] = '$INITIAL_ROOT_PASSWORD';" \
        gitlab/gitlab-ce:latest
    fi


    echo "Waiting for GitLab to be ready..."
    # 1. Wait for GitLab to be up and running
    while ! curl -s "http://$GITLAB_HOSTNAME/users/sign_in" | grep -q 'GitLab'; do
        echo -n "."
        sleep 15
    done

}

GITLAB_IP_ADDRESS=""
get_container_ip() {
    echo "Getting GitLab container IP address..."
    # Get the container ID of the GitLab hostname
    CONTAINER_ID=$(docker ps -aqf name=$GITLAB_HOSTNAME)
    # echo "CONTAINER_ID=$CONTAINER_ID"
        # Check if the container ID is empty
    if [[ -n "$CONTAINER_ID" ]]; then
      # Get the IP address of the GitLab container
      GITLAB_IP_ADDRESS=$(docker inspect -f '{{ .NetworkSettings.Networks.'$GITLAB_DOCKER_NETWORK_NAME'.IPAddress }}' $CONTAINER_ID)
      echo "The IP address of the GitLab container is: $GITLAB_IP_ADDRESS"
    else
      # The container ID is empty, so do nothing
      echo "The GitLab container is not running."
      create_gitlab_container
    fi
    # Output the GitLab IP address
}

create_user_and_get_token() {
    echo "Creating user and getting token..."
    # 2. Create a new user and get a token
    cat <<EOF > create_user_and_token.rb
    u = User.new(
      username: '$NEW_USER_NAME',
      email: '$NEW_USER_EMAIL',
      name: '$NEW_USER_NAME',
      password: '$NEW_USER_PASS',
      password_confirmation: '$NEW_USER_PASS',
      admin: true
    )
    u.skip_confirmation!
    u.save!

    u.update!(theme_id: 11) # 11 usually corresponds to the dark theme
    u.update!(color_scheme_id: 2) # 2 usually corresponds to the dark theme

    token = u.personal_access_tokens.create(
      scopes: ['api', 'create_runner','read_repository', 'write_repository', 'ai_features', 'sudo', 'admin_mode'],
      name: 'install_token',
      expires_at: 365.days.from_now
    )
    token.set_token('$NEW_USER_TOKEN')
    token.save!

    puts "Token created"
EOF

    docker cp create_user_and_token.rb $GITLAB_HOSTNAME:/tmp/create_user_and_token.rb
    docker exec -it $GITLAB_HOSTNAME /opt/gitlab/bin/gitlab-rails runner /tmp/create_user_and_token.rb
}



check_user_token(){
  echo "Checking user token..."
  # Fetch the authenticated user's data using the token
  RESPONSE=$(curl -s --header "PRIVATE-TOKEN: $NEW_USER_TOKEN" "$GITLAB_URL/api/v4/user")

  # Check if the response contains a "username" field, which indicates the token is valid
  if echo "$RESPONSE" | grep -q "username"; then
      echo "Token is valid."
  else
      echo "Token is NOT valid."
      create_user_and_get_token
  fi
}




create_runner_in_docker() {
    echo "Creating runner..."
    # Get instance-wide Runner
    cat <<EOF > get_runner_token.rb
    token = ApplicationSetting.current.runners_registration_token
    puts token
EOF
    docker cp get_runner_token.rb $GITLAB_HOSTNAME:/tmp/get_runner_token.rb
    RUNNER_TOKEN=$(docker exec -it $GITLAB_HOSTNAME /opt/gitlab/bin/gitlab-rails runner /tmp/get_runner_token.rb)

    # # For a project-specific Runner registration token
    # RUNNER_TOKEN=$(curl -s --header "PRIVATE-TOKEN: $NEW_USER_TOKEN" "http://$GITLAB_HOSTNAME/api/v4/projects?search=project1"  | jq '.[0] .runners_token' --raw-output)

    echo "RUNNER_TOKEN=$RUNNER_TOKEN"

    docker run -d --name gitlab-runner --restart always \
      --privileged=true \
      --network $GITLAB_DOCKER_NETWORK_NAME \
      --add-host=$GITLAB_HOSTNAME:$GITLAB_IP_ADDRESS \
      -v /var/run/docker.sock:/var/run/docker.sock \
      gitlab/gitlab-runner:latest


      # --network host \
      # --link $GITLAB_HOSTNAME:$GITLAB_HOSTNAME \
      # -v /srv/gitlab-runner/config:/etc/gitlab-runner \
      # -v /var/run/docker.sock:/var/run/docker.sock \
      # gitlab/gitlab-runner:latest

    docker exec -it gitlab-runner gitlab-runner register \
      --non-interactive \
      --url "$GITLAB_URL" \
      --docker-network-mode="bridge" \
      --docker-privileged="true" \
      --docker-extra-hosts="$GITLAB_HOSTNAME:$GITLAB_IP_ADDRESS" \
      --registration-token "$RUNNER_TOKEN" \
      --executor "docker" \
      --docker-image alpine:3 \
      --description "docker-runner" \
      --tag-list "docker03" \
      --run-untagged="false" \
      --locked="false" \
      --access-level="not_protected"

}


check_runner() {
    echo "Checking runner..."
    # Get the list of all Runners and Create if it is not present
    echo "Getting the list of all Runners..."
    RUNNERS_LIST=$(curl -s --header "PRIVATE-TOKEN: $NEW_USER_TOKEN" "$GITLAB_URL/api/v4/runners/all")
    # Check if the list is empty
    if [[ $(echo "$RUNNERS_LIST" | jq '. | length') -eq 0 ]]; then
        echo "No Runners found."
        get_container_ip
        create_runner_in_docker
        # install_docker_in_runner
        # create_runner_in_host
    else
        echo "Runners found:"
        echo "$RUNNERS_LIST" | jq '.[] | {description, id, status, contacted_at}'
    fi
}




get_container_ip
check_user_token
check_runner



# echo "Creating Project..."
# PROJECT_CREATE_RESULT=$(curl -s -k --request POST --header "PRIVATE-TOKEN: $NEW_USER_TOKEN" --header 'Content-Type: application/json' --data  '{"name": "'$PROJECT_NAME'", "description": "example","namespace": "name", "initialize_with_readme": "true"}' --url "$GITLAB_URL/api/v4/projects/")
# PROJECT_ID=$(echo "$PROJECT_CREATE_RESULT" | jq '.id')
# echo "NEW PROJECT_ID=$PROJECT_ID"
# # Check if the project ID not equal to null
# if [[ $PROJECT_ID != "null" ]]; then
#     echo "Project created successfully."
# else
#     echo "Project creation failed."
#     echo "$PROJECT_CREATE_RESULT" | jq
# fi



PROJECT_ID=""
get_project_id() {
  echo "Getting Project ID..."
  # Fetch the project data from GitLab API
  PROJECT_DATA=$(curl -s --header "PRIVATE-TOKEN: $NEW_USER_TOKEN" "$GITLAB_URL/api/v4/projects?search=$1")
  # Extract the project ID
  PROJECT_ID=$(echo "$PROJECT_DATA" | jq '.[0].id')

  echo "Found Project $PROJECT_NAME with ID: $PROJECT_ID"
}



# Add a CI/CD variable to the project
gitlab_add_cicd_variable() {
  echo "Adding CI/CD variable..."
  curl -s --request POST --header "PRIVATE-TOKEN: $NEW_USER_TOKEN" \
     --data "key=$2&value=$3" \
     "$GITLAB_URL/api/v4/projects/$1/variables" | jq
}

add_tag(){
  echo "Adding tag..."
  curl -s --request POST --header "PRIVATE-TOKEN: $NEW_USER_TOKEN" \
  --data "tag_name=$3" \
  --data "ref=$2" \
  --data "message=$4" \
  "$GITLAB_URL/api/v4/projects/$1/repository/tags"
}

delete_tag(){
  echo "Delete tag..."
  curl -s --request DELETE --header "PRIVATE-TOKEN: $NEW_USER_TOKEN" \
  "$GITLAB_URL/api/v4/projects/$1/repository/tags/$3"
}

cancel_all_pipelines() {
  echo "Cancelling all running pipelines for project $1..."
  # Define arguments
  # $1 "your_project_id"

  # Get list of running pipelines for the project
  pipelines=$(curl --silent --header "PRIVATE-TOKEN: $NEW_USER_TOKEN" "$GITLAB_URL/api/v4/projects/$1/pipelines?status=running" | jq '.[] .id')

  # Iterate over the pipeline IDs and cancel each one
  for pipeline_id in $pipelines; do
    echo "Cancelling pipeline $pipeline_id..."
    curl --request POST --silent --header "PRIVATE-TOKEN: $PRIVATE_TOKEN" "https://$GITLAB_DOMAIN/api/v4/projects/$PROJECT_ID/pipelines/$pipeline_id/cancel"
  done
}

# Create Project Group
# curl --request POST "http://$GITLAB_HOSTNAME/api/v4/groups" \
#      --header "Authorization: Bearer $NEW_USER_TOKEN" \
#      --header "Content-Type: application/json" \
#      --data '{
#        "name": "'$GROUP_NAME'",
#        "path": "'$GROUP_NAME'",
#        "description": "group for projects",
#        "visibility": "internal" 
#      }'
# ## private or "public" or "internal"

create_local_registry(){
  # if CI_REGISTRY_LOCAL is true, then create local registry
  if [[ $CI_REGISTRY_LOCAL == "true" ]]; then
    echo "Creating local registry..."
    mkdir auth
    $ docker run \
      --entrypoint htpasswd \
      httpd:2 -Bbn $CI_REGISTRY_USER $CI_REGISTRY_PASSWORD > auth/htpasswd

    docker run -d \
      -p 5000:5000 \
      --restart=always \
      --network $GITLAB_DOCKER_NETWORK_NAME \
      --name registry \
      -v "$(pwd)"/auth:/auth \
      -e "REGISTRY_AUTH=htpasswd" \
      -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
      -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
      registry:2

  fi
}

# push git reposotory frontend
cd ../frontend
rm -rf .gitlab-ci.yml
git add .
git commit -m "remove gitlab-ci.yml"
git remote set-url origin "http://oauth2:$NEW_USER_TOKEN@127.0.0.1/devops/frontend.git"
git push -u origin --all
# sleep 3
# get_project_id "frontend"
# cancel_all_pipelines $PROJECT_ID


# push git reposotory frontend_build
cd ../frontend_build
git add .
git commit -m "update gitlab-ci.yml"
git remote set-url origin "http://oauth2:$NEW_USER_TOKEN@127.0.0.1/devops/frontend-build.git"
git push -u origin --all
sleep 3

# Add Project variables for CI/CD
get_project_id $PROJECT_NAME
gitlab_add_cicd_variable $PROJECT_ID "GITLAB_URL_PREFIX" "http"
gitlab_add_cicd_variable $PROJECT_ID "GITLAB_URL_HOSTNAME" "$GITLAB_HOSTNAME"
gitlab_add_cicd_variable $PROJECT_ID "GITLAB_PATH_SRC_PROJECT" "$GITLAB_PATH_SRC_PROJECT"
gitlab_add_cicd_variable $PROJECT_ID "CI_JOB_TOKEN" "$NEW_USER_TOKEN"
gitlab_add_cicd_variable $PROJECT_ID "CI_REGISTRY" "$CI_REGISTRY"
gitlab_add_cicd_variable $PROJECT_ID "CI_REGISTRY_USER" "$CI_REGISTRY_USER"
gitlab_add_cicd_variable $PROJECT_ID "CI_REGISTRY_PASSWORD" "$CI_REGISTRY_PASSWORD"
# gitlab_add_cicd_variable $PROJECT_ID "DOCKER_HOST" "unix:///var/run/docker.sock"


delete_tag $PROJECT_ID main "v1.0.0"
add_tag $PROJECT_ID main "v1.0.0" "first tag"


# apt update; apt install -y inetutils-ping telnet curl net-tools
