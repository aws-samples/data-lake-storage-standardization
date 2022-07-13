#!/bin/bash
#set -x
pflag=false
fflag=false
eflag=false
rflag=false

DIRNAME_ROOT=$(dirname "$0")

# List of templates to deploy -- use space between each template
#  templates are deployed in the order listed here
# Example of on how to run the script -- for local only -- ./source/dl-foundation/deploy.sh -f apgdl -e dev -r ca-central-1 -p 46

TEMPLATE_DIRECTORIES="ssm-lambda replication-region-ssm replication-region-kms replication-region-s3 kms s3"

usage () { echo "
    -h -- Opens up this help message
    -f -- Framework prefix
    -e -- Environment
    -p -- Name of the AWS profile to use
    -r -- Primary REGION
"; }
options=':p:s:f:e:r:h'
while getopts $options option
do
    case "$option" in
        f  ) fflag=true; FRAMEWORK_PREFIX=$OPTARG;;
        e  ) eflag=true; ENV=$OPTARG;;
        p  ) pflag=true; PROFILE=$OPTARG;;
        r  ) rflag=true; REGION=$OPTARG;;
        h  ) usage; exit;;
        \? ) echo "Unknown option: -$OPTARG" >&2; exit 1;;
        :  ) echo "Missing option argument for -$OPTARG" >&2; exit 1;;
        *  ) echo "Unimplemented option: -$OPTARG" >&2; exit 1;;
    esac
done

if ! $fflag
then
    echo "-f not specified, using default..." >&2
    FRAMEWORK_PREFIX="cdl"
fi

if ! $pflag
then
    echo "-p not specified" >&2
    PROFILE=""
else
    PROFILE="--profile $PROFILE"
fi

if ! $rflag
then
    echo "-r not specified" >&2
    REGION=""
else
    aws configure set default.region $REGION
    REGION="--region $REGION"
fi


if ! $eflag
then
ENV=$(sed -e 's/^"//' -e 's/"$//' <<<"$(aws ssm get-parameter --name /$FRAMEWORK_PREFIX/Misc/pEnv --query "Parameter.Value" $PROFILE $REGION)")
fi

#substition of environment in tags
if [[ $ENV == "prod" ]] ; then
  TAG_ENV="prd"
elif [[ $ENV == "dev" ]] ; then
  TAG_ENV="dev"
elif [[ $ENV == "test" ]] ; then
  TAG_ENV="tst"
elif [[ $ENV == "tst" ]] ; then
  TAG_ENV="tst"
else
  TAG_ENV="npd"
fi
cat $DIRNAME_ROOT/tags.json | awk -v cuv2="$TAG_ENV" '{sub("{AWS:ENVIRONMENT}",cuv2); print;}' | awk -v cuv2="$FRAMEWORK_PREFIX" '{sub("{AWS:FRAMEWORK_PREFIX}",cuv2); print;}' > $DIRNAME_ROOT/tags-packaged.json


# Read a string with spaces using for loop
for DIR_NAME in $TEMPLATE_DIRECTORIES
do
  TEMPLATE_FILENAME="template-$DIR_NAME.yaml"
  STACK_NAME="$FRAMEWORK_PREFIX-$DIR_NAME"
  DIRNAME="$DIRNAME_ROOT/$DIR_NAME"

  # Check if it is replication template
  if [[ $DIR_NAME == replication* ]] ; then
    REPLICATION_REGION=$(sed -e 's/^"//' -e 's/"$//' <<<"$(aws ssm get-parameter --name /account/replica-dest-region --query "Parameter.Value" $PROFILE $REGION)")
  else
    REPLICATION_REGION=""
  fi


  #Stack region 
  if [[ $REPLICATION_REGION == "" || $REPLICATION_REGION == "N/A" || $REPLICATION_REGION == "n/a" ]] ; then
    STACK_REGION="$REGION"
    STACK_PARAMETERS_FILE="$DIRNAME/parameters-$ENV.json"
  else
    STACK_REGION="--region $REPLICATION_REGION"
    STACK_PARAMETERS_FILE="$DIRNAME_ROOT/ssm-lambda/parameters-$ENV.json"
  fi

  echo "*******"
  echo "*******"
  echo "Stack region ($STACK_REGION) exists ..."
  echo "Stack parameters ($STACK_PARAMETERS_FILE) exists ..."


  if [[ $DIR_NAME == replication* && ($REPLICATION_REGION == "" || $REPLICATION_REGION == "N/A" || $REPLICATION_REGION == "n/a") ]] ; then
    echo "Do not deploy stack ($STACK_NAME) ..."
  else

    echo "Checking if stack ($STACK_NAME) exists ..."
    unset STACK_EXISTS
    set +e
    STACK_EXISTS=$( aws cloudformation describe-stacks $PROFILE $STACK_REGION --stack-name $STACK_NAME 2>&1)
    status=$?
    set -e

    if [[ $STACK_EXISTS == *"ValidationError"* && $STACK_EXISTS == *"Stack with id $STACK_NAME does not exist"* ]] ; then
      echo -e "Stack ($STACK_NAME) does not exist, creating ..."

      aws cloudformation create-stack $PROFILE $STACK_REGION \
        --stack-name $STACK_NAME \
        --parameters  file://$STACK_PARAMETERS_FILE \
        --template-body file://$DIRNAME/$TEMPLATE_FILENAME \
        --tags file://$DIRNAME_ROOT/tags-packaged.json \
        --capabilities "CAPABILITY_NAMED_IAM" "CAPABILITY_AUTO_EXPAND"

      echo "Waiting for stack ($STACK_NAME) to be created ..."
      aws cloudformation wait stack-create-complete $PROFILE $STACK_REGION --stack-name $STACK_NAME

    else
      echo -e "Stack ($STACK_NAME) exists, attempting update ..."
      set +e
      update_output=$( aws cloudformation update-stack $PROFILE $STACK_REGION \
        --stack-name $STACK_NAME \
        --parameters file://$STACK_PARAMETERS_FILE \
        --template-body file://$DIRNAME/$TEMPLATE_FILENAME \
        --tags file://$DIRNAME_ROOT/tags-packaged.json \
        --capabilities "CAPABILITY_NAMED_IAM" "CAPABILITY_AUTO_EXPAND" 2>&1)
      status=$?
      set -e
      if [ $status -ne 0 ] ; then
        # Don't fail for no-op update
        if [[ $update_output == *"ValidationError"* && $update_output == *"No updates"* ]] ; then
          echo -e "\nFinished update - no updates to be performed ($STACK_NAME).";
        else
          echo "$update_output"
          exit $status
        fi
      else
        echo "Waiting for stack update to complete ..."
        aws cloudformation wait stack-update-complete $PROFILE $STACK_REGION \
          --stack-name $STACK_NAME
        echo "Finished update successfully ($STACK_NAME)!"

      fi # ending stack status
    fi # Ending - stack update or create
  fi # ending -  check if replication stacks should run.
done
