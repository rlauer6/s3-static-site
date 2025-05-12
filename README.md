# README

This project contains various scripts for creating a S3 + CloudFront
static website.

![CloudFront-S3 Flow](https://blog.tbcdevelopmentgroup.com/img/cf-s3-flow.png)

# Overview

Using these scripts you can:

* Create a private or public S3 hosted website
* Enable HTTPS for your private S3 based static website
* Request a certificate
* Update or create a custom domain name for your website

| Name | Description | Blog Post |
| ---- | ----------- | --------- |
| `s3-static-website.sh` | Create a private S3 backed static website | [Hosting a Secure Static Website with S3 and CloundFront](https://blog.tbcdevelopmentgroup.com/2025-02-18-post.html) |
| `s3-bucket-unlock.sh` | Unlock an S3 bucket by updating the bucket policy | [Hosting a Secure Static Website with S3 and CloundFront](https://blog.tbcdevelopmentgroup.com/2025-02-21) | |
| `update-route53.sh` | Update Route 53 | |
| `request-certificate.sh` | Create a certificiate for your distribution. | |
| `create-route53-alias.sh` | Create an alias for your distribution. | |
| `delete-s3-static-site.sh` | Tear down the distribution | |

# The Goal

* Create an S3 bucket based website fronted by CloudFront
* Serve pages over HTTPS
* Use a custom domain name in a private (or public) Route53 hosted zone
* Optionally restrict access to only IPs in that hosted zone (or additional
  public IP addresses)

## Assumptions

* You have an AWS account
* You have a private (or public) hosted zone in this or another AWS
  account
* You have IAM permissions that allow you to:
  - Create and modify buckets
  - Create CloudFront distributions
  - Create WAF rules 
  - Request ACM certificates
  
> Note that these scripts allow you to pass a profile argument for
> both the Route 53 account and the account that will host your
> distribution. If they are the same then both arguments are not
> requried. Check the usage notes for each script.

## Steps

1. Request an ACM certificate. This will request a certificate and
   setup DNS validation. Use the -r option to set the profile for your
   Route53 account if it is a different account than your distribution.
   ```
   request-certificate.sh -d cpan.openbedrock.net -c my-profile -z openbedrock.net
   ```
2. Create the S3 + Cloudfront website. Using the certificate you
   created above, find it's ARN and use the -c option to provide that
   during creation time (optional - the script will look for a
   certificate with the alternate domain name you provided). If you
   provide an alternate domain name, you must have a certificate
   already installed in ACM.
   ```
   s3-static-website.sh -p my-profile -b bucket-name \
      -c certificate-arn -a alternate-domain-name
   ```
   
   The script is designed to be idempotent. If any step fails you
   should be able to re-run the script safely.
   
3. Create an alias in Route53 for your distribution. Use the -t option
   if you've tagged the distribution when you created it or provide the
   distribution id using the -d option.
   ```
   update-route53.sh -d DISTRIBUTION-ID -p ROUTE53-PROFILE \
      -C CLOUDFRONT-PROFILE \
      -z HOSTED_ZONE -n SUBDOMAIN_NAME
   ```

You should now have a fully working S3 + CloudFront distribution.

## Tearing Down the Distribution

Run the `delete-s3-static-site.sh` script if you want to delete the
distribution. If you want to delete the bucket, provide the bucket
name with the -b option.
> Bucket must be empty before you attempt to delete the bucket.

```
./delete-s3-static-site.sh -b BUCKET-NAME -d DOMAIN -c DISTRIBUTION-ID \
   -p CLOUDFRONT-PROFILE -r ROUTE53-PROFILE -z HOSTED-ZONE-NAME
```

* You do not need to delete the bucket when deleting the distribution.
* If the Route 53 account is the same as the account hosting your
  distribution you do not need to provide the -r option.

## Static Website Hosting Cost Estimate (S3 + CloudFront + Route 53)

This is a typical monthly cost estimate for hosting a static website using AWS S3, CloudFront, ACM, and Route 53 — based on 25 GB of storage and moderate web traffic.

---

### Monthly Cost Overview

| Service        | Description                                      | Estimated Cost |
|----------------|--------------------------------------------------|----------------|
| **S3**         | 25 GB Standard storage + 1M GET requests         | ~$1.00         |
| **CloudFront** | 25 GB egress + 1M HTTP requests (US region)      | ~$2.80         |
| **ACM**        | Public TLS cert for custom domain (via CloudFront) | Free         |
| **Route 53**   | 1 hosted zone + 1M DNS queries                   | ~$0.90         |
|                |                                                  |                |
| **Total**      |                                                  | **~$4.70/mo**  |

---

### S3 Breakdown

- 25 GB × $0.023/GB = **$0.58**
- 1 million GET requests × $0.0004 = **$0.40**

---

### CloudFront Breakdown

- 1 GB free + 24 GB × $0.085 = **$2.04**
- 1 million HTTP requests × $0.0075 per 10,000 = **$0.75**

---

### ACM (AWS Certificate Manager)

- Public certificates are **free** when used with CloudFront (must be in `us-east-1`)

---

### Route 53

- Hosted zone = **$0.50**
- DNS queries (1 million) = **$0.40**

---

### Notes

- CloudFront includes **1 GB free egress** per month
- Costs can increase if:
  - You serve globally (non-US data transfer)
  - You use advanced features like WAF, Shield, or Lambda@Edge
- No charges for using an S3 static website alone, but you must front it with CloudFront to use HTTPS with a custom domain


# `s3-static-website.sh`

```
Usage: $0 -b BUCKET_NAME -p AWS_PROFILE [-r AWS_REGION] [-o OAC_NAME]

Options:
  -b    (Required) S3 Bucket Name
  -p    (Required) AWS Profile (or set AWS_PROFILE in the environment)
  -P    Make site public (skips IP restriction via WAF)
  -r    AWS Region (default: us-east-1)
  -o    CloudFront OAC Name (default: Derived from Bucket Name)
  -a    alternate domain name
  -c    certificate arn
  -i    IP list in CIDR notation of additional public ips
  -h    Display this help message
  -t    Environment tag value (used to find NAT gateway)
  -T    default TTL for CloudFront caching, default: 31536000 (1 year)
  -m    minimum TTL for CloudFront caching, default: 86400 (1 day)
```

# `update-route53.sh` 

Run this script if you want your static bucket to have it's own domain
name.

```
Usage: ./update-route53.sh -d DISTRIBUTION_ID -t TAG_VALUE -p AWS_PROFILE -n SUBDOMAIN_NAME -z HOSTED_ZONE

Options:
  -d    CloudFront distribution ID (e.g., E1XYZABCDEF)**
  -p    AWS Profile
  -P    Indicates Hosted Zone is public
  -t    Name tag value**
  -n    Subdomain name (e.g., cpan.example.com)
  -z    Route 53 hosted zone name (e.g., example.com)
```

# `request-certfificate.sh`

```
Usage: $0 -d DOMAIN -c CERT_PROFILE -r ROUTE53_PROFILE -z ZONE_DOMAIN

Options:
  -d  Fully qualified domain name (e.g. cpan.openbedrock.net)
  -c  AWS CLI profile for ACM/CloudFront (e.g. account-a)
  -r  AWS CLI profile for Route 53 zone (e.g. account-b)
  -z  Route 53 base domain name (e.g. openbedrock.net)
  -Z  Hosted zone id (optional)
```

# `create-route53-alias.sh`

Creates a DNS entry for your CloudFront distribution. Use the
`update-route53.sh` after you setup your distribution. This is script
is just a generic version demonstrating how to setup an alias in Route53.

```
Usage: $0 -d DOMAIN -z ZONE_DOMAIN -c DISTRIBUTION_ID -p CLOUDFRONT_PROFILE -r ROUTE53_PROFILE

Options:
  -d  Fully qualified domain name (e.g. cpan.openbedrock.net)
  -z  Route 53 base domain (e.g. openbedrock.net)
  -c  CloudFront distribution ID
  -p  AWS CLI profile for CloudFront (e.g. account-a)
  -r  AWS CLI profile for Route 53 (e.g. account-b)
```
