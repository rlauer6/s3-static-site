#!/usr/bin/env bash
# -*- mode: sh; -*-

set -e

########################################################################
usage() {
########################################################################
    cat <<EOF
Usage: $0 -i <home-ip> -b <bucket-name> [-v <vpc-id>] [-p <aws-profile>] [-n]

  -i  <home-ip> Your home IP address (e.g., 203.0.113.25)
  -b  <bucket>  S3 bucket name
  -v  <vpc-id>  Optional: VPC ID (auto-detected if running on EC2)
  -p  <profile> Optional: AWS CLI profile (sets AWS_PROFILE environment variable)
  -n            Dry run (show policy, do not apply)
EOF
    exit 1
}

########################################################################
# MAIN SCRIPT STARTS HERE
########################################################################

HOME_IP=""
BUCKET=""
VPC_ID=""
PROFILE=""
DRY_RUN=""

AWS=$(command -v aws)

if test -z "$AWS"; then
    echo "error: install 'aws' CLI or make sure it's in your PATH"
    exit 1
fi

CURL=$(command -v curl)

if test -z "$CURL"; then
    echo "error: install 'curl' or make sure it's in your PATH"
    exit 1
fi

while getopts ":i:b:v:p:n" opt; do
  case ${opt} in
    i ) HOME_IP="$OPTARG" ;;
    b ) BUCKET="$OPTARG" ;;
    v ) VPC_ID="$OPTARG" ;;
    p ) PROFILE="$OPTARG" ;;
    n ) DRY_RUN="1" ;;
    * ) usage ;;
  esac
done

if [[ -z "$HOME_IP" || -z "$BUCKET" ]]; then
    usage
fi

if [[ -n "$PROFILE" ]]; then
    export AWS_PROFILE="$PROFILE"
    echo "Using AWS_PROFILE=$AWS_PROFILE"
fi

if [[ -z "$VPC_ID" ]]; then
    # Attempt to get VPC ID from instance metadata (if running on EC2)
    if $CURL -s --max-time 2 http://169.254.169.254/latest/meta-data/ >/dev/null; then
        MAC=$($CURL -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/)
        VPC_ID=$($CURL -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC}/vpc-id)
        echo "Detected VPC ID from instance metadata: $VPC_ID"
    else
        echo "No VPC ID provided and not running on EC2. Exiting."
        exit 1
    fi
fi

POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowVPCAndHomeAccess",
            "Effect": "Allow",
            "Principal": "*",
             "Action": ["s3:ListBucket", "s3:GetObject"],
               "Resource": [
                   "arn:aws:s3:::$BUCKET",
                   "arn:aws:s3:::$BUCKET/*"
                ],
             "Condition": {
                "IpAddressIfExists": { "aws:SourceIp": ["$HOME_IP/32"] },
                "StringEqualsIfExists": { "aws:SourceVpc": "$VPC_ID" }
            }
        },
        {
            "Sid": "AllowVPCPolicyUpdate",
                        "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:PutBucketPolicy",
            "Resource": "arn:aws:s3:::$BUCKET",
            "Condition": {
                "StringEquals": { "aws:SourceVpc": "$VPC_ID" }
            }
        },
        {
            "Sid": "DenyAllOthers",
            "Effect": "Deny",
            "Principal": "*",
            "Action": "s3:*",
            "Resource": "arn:aws:s3:::$BUCKET",
            "Condition": {
                "StringNotEqualsIfExists": { "aws:SourceVpc": "$VPC_ID" },
                "NotIpAddressIfExists": { "aws:SourceIp": ["$HOME_IP/32"] }
            }
        }
    ]
}
EOF
)

if test -n "$DRY_RUN"; then
    echo "Dry run mode enabled. Policy would be:"
    echo "$POLICY"
else
    $AWS s3api put-bucket-policy --bucket "$BUCKET" --policy "$POLICY"
    echo "Policy applied to bucket $BUCKET."
fi
