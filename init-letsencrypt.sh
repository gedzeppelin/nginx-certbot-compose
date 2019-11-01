#!/bin/bash

if ! [ -x "$(command -v docker-compose)" ]; then
  echo 'Error: docker-compose is not installed.' >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  echo "Specify at least one domain:path."
  exit
fi

declare -a domains
declare -a domain_paths

for arg in $@; do
  IFS=':' read -ra domain_path <<< "$arg"
  if [[ ! ${#domain_path[@]} -eq 2 ]]; then
    echo "$arg isn't a valid domain:path string."
    exit
  fi
  if [[ ${domain_path[0]^^} =~ ^([A-Z0-9][A-Z0-9-]{0,60}[A-Z0-9]\.)*[A-Z0-9][A-Z0-9-]{0,60}[A-Z0-9]\.[A-Z]{2,10}$ ]]; then
    domains+=(${domain_path[0],,})
  else
    echo "$arg isn't a valid domain name."
    exit
  fi
  if [[ ! ${domain_path[1]^^} =~ ^[A-Z0-9-_\.]+$ ]]; then
    domain_paths+=($arg)
  else
    echo "${domain_path[1]} isn't a valid dir name."
    exit
  fi
done
IFS=' '

rsa_key_size=4096
certbot_conf_path="./data/certbot-conf"
nginx_conf_path="./data/nginx-conf"
# certbot_www_path="./data/certbot-www"
email="gedy.palomino@gmail.com"
staging=0 # Set to 1 if you're testing your setup to avoid hitting request limits

if [[ -d $certbot_conf_path ]] || [[ -d $nginx_conf_path ]]; then
  read -p "[WARNING] Existing config directories founded, continue and replace all the data? (y/N): " decision
  if [[ ! ${decision^^} =~ ^Y(ES)?$ ]]; then
    exit
  fi
fi

if [[ ! -w $certbot_conf_path ]] || [[ ! -x $certbot_conf_path ]] || [[ ! -w $nginx_conf_path ]] || [[ ! -x $nginx_conf_path ]]; then
  echo "[WARNING] You don't have enough permissions to do the requested actions or the directories doesn't exist."
  exit
fi

echo "[INFO] Generating the Nginx config files."
for domain_path in ${domain_paths[@]}; do
  IFS=':' read -ra domain_path_array <<< "$domain_path"
  cat > "$nginx_conf_path/${domain_path_array[0],,}.conf" << EOF
server {
    listen       80;
    listen       [::]:80;
    server_name  ${domain_path_array[0],,};
    
    location / {
        return 301 https://\$host\$request_uri;
    }

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }                          
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    ssl_certificate /etc/letsencrypt/live/${domain_path_array[0],,}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain_path_array[0],,}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    server_name ${domain_path_array[0],,};
    
    location / {
	root   /html/${domain_path_array[1]};
	index  index.html;
    }
                                                             
    error_page 404 /404.html;
        location = /40x.html {
    }
                                                             
    error_page 500 502 503 504 /50x.html;
        location = /50x.html {
    }
}
EOF
done
IFS=' '

if [[ ! -e $certbot_conf_path/options-ssl-nginx.conf ]] || [[ ! -e $certbot_conf_path/ssl-dhparams.pem ]]; then
  echo "[INFO] Downloading recommended TLS parameters."
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/tls_configs/options-ssl-nginx.conf > "$certbot_conf_path/options-ssl-nginx.conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/ssl-dhparams.pem > "$certbot_conf_path/ssl-dhparams.pem"
  echo
fi

for domain in ${domains[@]}; do
  echo "[INFO] Creating dummy certificate for $domain"
  path="/etc/letsencrypt/live/$domain"
  mkdir -p "$certbot_conf_path/live/$domain"
  docker-compose run --rm --entrypoint "\
    openssl req -x509 -nodes -newkey rsa:1024 -days 1\
      -keyout '$path/privkey.pem' \
      -out '$path/fullchain.pem' \
      -subj '/CN=localhost'" certbot
  echo
done


echo "[INFO] Starting nginx."
docker-compose up --force-recreate -d nginx
echo

for domain in ${domains[@]}; do
  echo "[INFO] Deleting dummy certificate for $domain."
  docker-compose run --rm --entrypoint "\
    rm -Rf /etc/letsencrypt/live/$domain && \
    rm -Rf /etc/letsencrypt/archive/$domain && \
    rm -Rf /etc/letsencrypt/renewal/$domain.conf" certbot
  echo
done


echo "[INFO] Requesting Let's Encrypt certificate for ${domains[@]}"
#Join $domains to -d args
# domain_args=""
# for domain in ${domains[@]}; do
#   domain_args="$domain_args -d $domain"
# done

# Select appropriate email arg
case "$email" in
  "") email_arg="--register-unsafely-without-email" ;;
  *) email_arg="--email $email" ;;
esac

# Enable staging mode if needed
if [ $staging != "0" ]; then staging_arg="--staging"; fi

for domain in ${domains[@]}; do
  docker-compose run --rm --entrypoint "\
    certbot certonly --webroot -w /var/www/certbot \
      $staging_arg \
      $email_arg \
      -d $domain \
      --rsa-key-size $rsa_key_size \
      --agree-tos \
      --force-renewal" certbot
  echo
done

echo "[INFO] Reloading nginx."
docker-compose exec nginx nginx -s reload

echo "[INFO] Removing containers."
docker-compose stop
docker-compose rm -f

echo "[OK] Feel free to run docker-compose up"
