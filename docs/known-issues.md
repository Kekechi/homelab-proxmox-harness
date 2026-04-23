# Know Issues
## apt package TLS migration dependency
APT debian source and auth gets updated in ansible common role\
Specific apt packages such as step-ca, dns-dist, dns-auth does not get updated during common, so fails `apt update`\
