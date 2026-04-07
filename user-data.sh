
#!/bin/bash
yum update -y
yum install -y nginx
systemctl enable nginx
systemctl start nginx

echo '<html><body style="background-color:gray;"><h1>EC2 GRAY server</h1></body></html>' > /usr/share/nginx/html/index.html
systemctl reload nginx
