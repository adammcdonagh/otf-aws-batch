#!/bin/bash
PROFILE=$1
AWS_ACCOUNT_ID=$(aws --profile=${PROFILE} sts get-caller-identity --query Account --output text)
REGION=eu-west-1

IMAGE_NAME=opentaskpy-aws
IMAGE_TAG=latest

CONFIG_EFS_VOLUME_NAME=otf-config
CONFIG_EFS_VOLUME_ID=
LOGS_EFS_VOLUME_NAME=otf-logs
LOGS_EFS_VOLUME_ID=

# Build the docker image
docker build -t ${IMAGE_NAME}:${IMAGE_TAG} .

# We need to upload the image to ECR
# Check whether the repository exists, if not, then create it
if [ "$(aws --profile ${PROFILE} ecr describe-repositories --repository-names ${IMAGE_NAME})" ]; then
    echo "Repository already exists"
else
    echo "Repository does not exist, creating it"
    aws --profile ${PROFILE} ecr create-repository --repository-name ${IMAGE_NAME}
fi

# Get the login command from ECR and execute it directly
$(aws --profile ${PROFILE} ecr get-login --no-include-email)
# Get the repository URI
REPOSITORY_URI=$(aws --profile ${PROFILE} ecr describe-repositories --repository-names ${IMAGE_NAME} | jq -r '.repositories[0].repositoryUri')

# Tag the image so that we can push it to the repository
docker tag ${IMAGE_NAME}:${IMAGE_TAG} ${REPOSITORY_URI}:${IMAGE_TAG}

# Check if the image is in the repo already with this digest
if [ "$(aws --profile ${PROFILE} ecr list-images --repository-name ${IMAGE_NAME} | jq -r '.imageIds[] | select(.imageDigest == "'$(docker inspect --format='{{index .RepoDigests 0}}' ${REPOSITORY_URI}:${IMAGE_TAG} | cut -d '@' -f 2)'")')" ]; then
    echo "Image already exists in the repository"
else
    echo "Image does not exist in the repository, pushing it"
    # Push the image to the repository
    docker push ${REPOSITORY_URI}:${IMAGE_TAG}
fi

# Create 2x EFS volumes. One for logs, the other for the config
# Loop through 2 the volume types
for VOLUME_TYPE in $CONFIG_EFS_VOLUME_NAME $LOGS_EFS_VOLUME_NAME; do
    # Check whether the EFS volume exists, if not, then create it
    if [ "$(aws --profile ${PROFILE} efs describe-file-systems | jq -r '.FileSystems[].Name' | grep ${VOLUME_TYPE})" ]; then
        echo "EFS volume already exists"
    else
        echo "EFS volume does not exist, creating it"
        aws --profile ${PROFILE} efs create-file-system --creation-token ${VOLUME_TYPE} --tags Key=Name,Value=${VOLUME_TYPE} 
    fi
    # Get the volume ID for each and save it in a variable
    VOLUME_ID=$(aws --profile ${PROFILE} efs describe-file-systems | jq -r '.FileSystems[] | select(.Name == "'${VOLUME_TYPE}'") | .FileSystemId')
    if [ $VOLUME_TYPE == $CONFIG_EFS_VOLUME_NAME ]; then
        CONFIG_EFS_VOLUME_ID=${VOLUME_ID}
    elif [ $VOLUME_TYPE == $LOGS_EFS_VOLUME_NAME ]; then
        LOGS_EFS_VOLUME_ID=${VOLUME_ID}
    fi
done

# Print the 2x volume IDs
echo "Config volume ID: ${CONFIG_EFS_VOLUME_ID}"
echo "Logs volume ID: ${LOGS_EFS_VOLUME_ID}"


# Create an execution role for a Fargate Task to run
# Check whether the role exists, if not, then create it
if [ "$(aws --profile ${PROFILE} iam list-roles | jq -r '.Roles[].RoleName' | grep ${IMAGE_NAME})" ]; then
    echo "Role already exists"
else
    echo "Role does not exist, creating it"
    # Create the trust-policy.json file
    cat << EOF > trust-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ecs-tasks.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
    aws --profile ${PROFILE} iam create-role --role-name ${IMAGE_NAME} --assume-role-policy-document file://trust-policy.json
    aws --profile ${PROFILE} iam attach-role-policy --role-name ${IMAGE_NAME} --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
fi

# We need to create a task definition
# Write the definition to a JSON file
cat << EOF > task-definition.json
{
  "type": "container",
  "containerProperties": {
    "image": "${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${IMAGE_NAME}:${IMAGE_TAG}",
    "command": [
      "task-run",
      "-c",
      "/config",
      "-v"
    ],
    "resourceRequirements": [
      {
        "type": "VCPU",
        "value": "1.0"
      },
      {
        "type": "MEMORY",
        "value": "2048"
      }
    ],
    "fargatePlatformConfiguration": {
      "platformVersion": "LATEST"
    },
    "networkConfiguration": {},
    "ephemeralStorage": {
        "sizeInGiB": 21
    },
    "executionRoleArn": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${IMAGE_NAME}",
    "jobRoleArn": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${IMAGE_NAME}",
    "environment": [
      {
        "name": "TASK_ID",
        "value": ""
      },
      {
        "name": "RUN_ID",
        "value": ""
      }
    ],
    "secrets": [],
    "linuxParameters": {},
    "mountPoints": [],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {},
      "secretOptions": []
    }
  },
  "platformCapabilities": [
    "FARGATE"
  ],
  "jobDefinitionName": "${IMAGE_NAME}",
  "timeout": {},
  "retryStrategy": {},
  "parameters": {}
}
EOF

# Use the JSON above to create a new task in AWS Batch
# Check whether the task definition exists, if not, then create it
if [ "$(aws --profile ${PROFILE} batch describe-job-definitions | jq -r '.jobDefinitions[] | select(.status == "ACTIVE")')" ]; then
    echo "Task definition already exists"
else
    echo "Task definition does not exist, creating it"
    aws --profile ${PROFILE} batch register-job-definition --cli-input-json file://task-definition.json
fi

# We need to create a service linked role for the compute resource
# Check whether the role exists, if not, then create it
# if [ "$(aws --profile ${PROFILE} iam list-roles | jq -r '.Roles[].RoleName' | grep AWSServiceRoleForBatch)" ]; then
#     echo "Role already exists"
# else
#     echo "Role does not exist, creating it"
#     aws --profile ${PROFILE} iam create-service-linked-role --aws-service-name batch.amazonaws.com
# fi


#  Get a list of the default subnets
SUBNETS=$(aws --profile ${PROFILE} ec2 describe-subnets | jq -r '.Subnets[] | select(.DefaultForAz == true) | .SubnetId' | jq -R . | jq -s .)
# Get a list of the default security groups
SECURITY_GROUPS=$(aws --profile ${PROFILE} ec2 describe-security-groups | jq -r '.SecurityGroups[] | select(.GroupName == "default") | .GroupId' | jq -R . | jq -s .)

# Define a Fargate compute environment JSON file
# Write the definition to a JSON file
cat << EOF > fargate-compute-definition.json
{
  "computeResources": {
    "type": "FARGATE",
    "maxvCpus": 1,
    "subnets": ${SUBNETS},
    "securityGroupIds": ${SECURITY_GROUPS}
  },
  "type": "MANAGED",
  "state": "ENABLED",
  "computeEnvironmentName": "opentaskpy-1"
}
EOF

# Check and create a fargate compute environment
# Check whether the compute environment exists, if not, then create it
if [ "$(aws --profile ${PROFILE} batch describe-compute-environments | jq -r '.computeEnvironments[] | select(.state == "ENABLED")')" ]; then
    echo "Compute environment already exists"
else
    echo "Compute environment does not exist, creating it"
    aws --profile ${PROFILE} batch create-compute-environment --cli-input-json file://fargate-compute-definition.json
fi

# Create a job queue if one doesnt exist
# Check whether the job queue exists, if not, then create it
if [ "$(aws --profile ${PROFILE} batch describe-job-queues | jq -r '.jobQueues[] | select(.status == "ENABLED")')" ]; then
    echo "Job queue already exists"
else
    echo "Job queue does not exist, creating it"
    aws --profile ${PROFILE} batch create-job-queue --job-queue-name ${IMAGE_NAME} --priority 1 --state ENABLED --compute-environment-order order=1,computeEnvironment=opentaskpy-1
fi

# Submit a new job to AWS Batch
# Define the job JSON file
cat << EOF > job.json
{
  "jobName": "job-test-1",
  "jobDefinition": "arn:aws:batch:eu-west-1:${AWS_ACCOUNT_ID}:job-definition/${IMAGE_NAME}:2",
  "jobQueue": "arn:aws:batch:eu-west-1:${AWS_ACCOUNT_ID}:job-queue/${IMAGE_NAME}",
  "dependsOn": [],
  "arrayProperties": {},
  "retryStrategy": {},
  "timeout": {},
  "parameters": {},
  "containerOverrides": {
    "command": [
      "task-run",
      "-v",
      "-c",
      "/config"
    ],
    "resourceRequirements": [],
    "environment": []
  }
}
EOF



# Create a schedule in eventbridge to trigger ECS task
# Define the schedule JSON file
cat << EOF > schedule.json
{
  "Name": "schedule-test-1",
  "ScheduleExpression": "rate(1 minute)",
  "State": "ENABLED",
  "Description": "Schedule to run a task",
  "Targets": [
    {
      "Id": "target-1",
      "Arn": "arn:aws:events:eu-west-1:${AWS_ACCOUNT_ID}:rule/schedule-test-1",
      "RoleArn": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${IMAGE_NAME}",
      "EcsParameters": {
        "TaskDefinitionArn": "arn:aws:batch:eu-west-1:${AWS_ACCOUNT_ID}:job-definition/${IMAGE_NAME}:2",
        "TaskCount": 1,
        "LaunchType": "FARGATE",
        "NetworkConfiguration": {
          "AwsVpcConfiguration": {
            "Subnets": ${SUBNETS},
            "SecurityGroups": ${SECURITY_GROUPS},
            "AssignPublicIp": "ENABLED"
          }
        },
        "PlatformVersion": "LATEST"
      }
    }
  ]
}
EOF

# Check whether the schedule exists, if not, then create it
if [ "$(aws --profile ${PROFILE} scheduler list-schedules | jq -r '.Rules[] | select(.Name == "schedule-test-1")')" ]; then
    echo "Schedule already exists"
else
    echo "Schedule does not exist, creating it"
    aws --profile ${PROFILE} scheduler create-schedule --cli-input-json file://schedule.json
fi