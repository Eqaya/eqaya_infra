# ---------------------------------------------------------------------------
# Production frontend hosting: private S3 origin + CloudFront (SPA) + ACM cert.
#
# Served at https://www.eqaya.com. eqaya.com's DNS is on GoDaddy (not Route53),
# so two records are added MANUALLY in GoDaddy (see the frontend_* outputs):
#   1. the ACM DNS-validation CNAME (one-time, to issue the cert)
#   2. www.eqaya.com  CNAME  ->  the CloudFront domain
# The apex eqaya.com is 301-forwarded to https://www.eqaya.com at the registrar
# (GoDaddy "Forward only" — NOT masking, or the frame-ancestors CSP blocks it).
#
# The cert MUST be in us-east-1 for CloudFront; the default provider already is.
# ---------------------------------------------------------------------------

locals {
  frontend_domain = "www.${var.domain_name}"
}

# --- S3 origin bucket (private; reachable only via CloudFront OAC) ---
resource "aws_s3_bucket" "frontend" {
  bucket = "eqaya-prod-frontend-${data.aws_caller_identity.current.account_id}"
  tags   = local.tags
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# --- ACM certificate for www.eqaya.com (DNS-validated via GoDaddy) ---
resource "aws_acm_certificate" "frontend" {
  domain_name       = local.frontend_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}

# Waits until the cert is ISSUED. The validation CNAME lives in GoDaddy (added
# manually from the frontend_cert_validation output); ACM polls public DNS, so
# this completes once that record propagates.
resource "aws_acm_certificate_validation" "frontend" {
  certificate_arn         = aws_acm_certificate.frontend.arn
  validation_record_fqdns = [for o in aws_acm_certificate.frontend.domain_validation_options : o.resource_record_name]
}

# --- Security headers on every SPA response ---
# The backend (helmet) already hardens api.eqaya.com; this mirrors it for the
# S3-served frontend, which otherwise ships with no security headers at all.
# Keep in sync with the dev mirror: /etc/nginx/snippets/eqaya-security-headers.conf
# on the dev box. The CSP allowlist covers everything the SPA loads: Google
# Maps/Places, Google Sign-In, reCAPTCHA, Google Fonts, GA4, S3 media, and the
# API + websockets. style-src keeps 'unsafe-inline' (MUI injects inline
# styles); script-src does NOT — the built index.html has no inline scripts,
# and Mozilla Observatory docks 20 points for 'unsafe-inline' in script-src.
resource "aws_cloudfront_response_headers_policy" "frontend_security" {
  name = "${local.name_prefix}-frontend-security-headers"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
    content_security_policy {
      content_security_policy = join("; ", [
        "default-src 'self'",
        "script-src 'self' https://accounts.google.com https://maps.googleapis.com https://places.googleapis.com https://www.google.com https://www.gstatic.com https://www.googletagmanager.com",
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://accounts.google.com",
        "font-src 'self' data: https://fonts.gstatic.com",
        "img-src 'self' data: blob: https://*.amazonaws.com https://*.googleapis.com https://*.gstatic.com https://*.google.com https://*.googleusercontent.com",
        "connect-src 'self' https://api.eqaya.com wss: https://*.google-analytics.com https://*.googleapis.com https://accounts.google.com https://www.googletagmanager.com",
        "frame-src https://www.google.com https://accounts.google.com",
        "worker-src 'self' blob:",
        "object-src 'none'",
        "frame-ancestors 'none'",
        "base-uri 'self'",
        "form-action 'self'",
      ])
      override = true
    }
  }

  custom_headers_config {
    items {
      header   = "Permissions-Policy"
      value    = "geolocation=(self), camera=(self), microphone=(self), payment=(), usb=()"
      override = true
    }
  }
}

# --- CloudFront Origin Access Control (keeps the bucket fully private) ---
resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${local.name_prefix}-frontend-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = [local.frontend_domain]
  comment             = "${local.name_prefix} frontend"
  price_class         = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  # Backend origin for server-rendered share/OG pages (WhatsApp link previews).
  origin {
    domain_name = "api.${var.domain_name}"
    origin_id   = "api-share"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # /share/* is rendered by the backend so crawlers get real OG meta tags
  # instead of the SPA shell. Never cached; Host is rewritten to the origin's
  # (AllViewerExceptHostHeader) so the ALB routes it to the API.
  ordered_cache_behavior {
    path_pattern           = "/share/*"
    target_origin_id       = "api-share"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    # AWS managed "CachingDisabled" cache policy.
    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    # AWS managed "AllViewerExceptHostHeader" origin request policy.
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
  }

  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    # AWS managed "CachingOptimized" policy.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    # Not attached to the /share/* behavior — the backend (helmet) already
    # sets its own headers there and they should win.
    response_headers_policy_id = aws_cloudfront_response_headers_policy.frontend_security.id
  }

  # SPA client-side routing: any missing key returns index.html (200) so deep
  # links like /dashboard resolve to the app instead of an S3 error.
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }
  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.frontend.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = local.tags
}

# --- Bucket policy: only this CloudFront distribution may read objects ---
resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn
        }
      }
    }]
  })
}
