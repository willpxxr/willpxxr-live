moved {
    from     = cloudflare_record.main["git"]
    to       = cloudflare_record.main["records/git/a"]
}

moved {
    from     = cloudflare_record.main["www"]
    to       = cloudflare_record.main["records/www/a"]
}

moved {
    from     = cloudflare_record.main["willpxxr.com"]
    to       = cloudflare_record.main["records/@/a"]
}

moved {
    from     = cloudflare_record.main["@"]
    to       = cloudflare_record.main["records/@/txt"]
}
