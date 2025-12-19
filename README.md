# 🎓 EduCMS

**EduCMS** is a **production-ready, Persian-first Learning Management System (LMS)** built with **Django** and **Docker**, designed for fast deployment, flexibility, and real-world usage.

It includes an **auto installer**, **admin panel**, **course management**, **ticketing system**, **bank transfer payments**, **discounts**, **SSL automation**, and much more — all managed through a single Bash script.

---

## ✨ Features

- 🚀 **One-line installation** (auto installer)
- 🐳 **Docker & Docker Compose based**
- 🔐 **Automatic SSL (Let's Encrypt)** on host
- 🎓 Course & category management
- 📹 Video upload (file or external link)
- 💳 Bank transfer payment system
- 🎟 Discount codes (percentage & fixed)
- 🎁 First purchase discount
- 👤 User registration & authentication
- 🧑‍💼 Admin panel with role-based permissions
- 🔁 Change admin URL from panel
- 🧾 Orders & manual payment verification
- 🎫 Ticketing system with attachments
- 🌗 Light / Dark / System theme
- 🖌 Editable texts, footer & navigation from admin
- 💾 Database backup & restore (.sql)
- 🇮🇷 Persian (Farsi) UI – RTL ready
- 📦 Production-ready (Gunicorn + Nginx)

---

## 🖥️ Live Stack Overview

| Layer | Technology |
|-----|-----------|
| Backend | Django 5 |
| Database | MySQL 8 |
| Web Server | Nginx |
| App Server | Gunicorn |
| Container | Docker |
| SSL | Let's Encrypt (Certbot) |

---

## 🚀 Installation (One-Line)

You can install **EduCMS** using a single Bash command.

Just copy & paste this into your server terminal:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/admin6501/EduCMS/refs/heads/main/install.sh)

💡 This command will:

Download the installer securely

Open the interactive EduCMS menu

Guide you through full installation

Install Docker, Docker Compose, SSL, and all dependencies automatically



---

🧭 Installer Menu

After running the command, you will see:

1) Install (نصب کامل)
2) Stop (توقف)
3) Restart (ری‌استارت)
4) Uninstall (حذف کامل)
5) Backup DB (.sql)
6) Restore DB (.sql)
0) Exit


---

⚙️ Requirements

Ubuntu 20.04 / 22.04 / 24.04

Root access (sudo)

A domain pointing to your server IP

Open ports: 80 and 443


> Docker and all required packages are installed automatically.




---

🔐 SSL & Security

SSL certificates are issued automatically using Let's Encrypt

Certificates are handled on the host, not inside Docker

Auto-renew is enabled via Certbot

Secure environment variables (.env)

Admin URL can be changed for extra security



---

💾 Database Backup

EduCMS includes a built-in database backup system.

Create Backup

1. Run the installer:



bash <(curl -sSL https://raw.githubusercontent.com/admin6501/EduCMS/refs/heads/main/install.sh)

2. Select:



5) Backup DB (.sql)

📁 Backup files are stored in:

/opt/educms/backups/

Each backup is a standard MySQL .sql file.


---

♻️ Database Restore

To restore a database backup:

1. Run the installer:



bash <(curl -sSL https://raw.githubusercontent.com/admin6501/EduCMS/refs/heads/main/install.sh)

2. Select:



6) Restore DB (.sql)

3. Enter the full path to the backup file:



/opt/educms/backups/educms-YYYYMMDD-HHMMSS.sql

⚠️ Warning:
This will completely replace the current database.


---

👤 Admin Panel

Default admin panel path:


/admin/

You can change the admin URL from inside the panel

Admins can:

Manage courses & categories

Upload videos

Verify payments

Manage tickets

Add other admins with permissions

Edit site texts, footer, links, branding

Change their username & password




---

🎫 Ticketing System

Users can create tickets

Attach files

View ticket history

Admins can reply directly from the admin panel



---

🧑‍🎓 User Features

Register & login

View purchased courses

Upload payment receipts

Use discount codes

Access free or granted courses

Submit and track tickets



---

📂 Project Structure

EduCMS/
├── app/                # Django project
├── nginx/              # Nginx configs
├── certbot/            # SSL webroot
├── backups/            # Database backups
├── docker-compose.yml
└── install.sh          # Auto installer


---

🧪 Tested On

Ubuntu 20.04 LTS

Ubuntu 22.04 LTS

Ubuntu 24.04 LTS



---

📄 License

This project is released under the MIT License.
You are free to use, modify, and distribute it.


---

⭐ Support the Project

If you find EduCMS useful:

⭐ Star the repository

🐛 Report issues

🤝 Contribute improvements



---

Built with ❤️ for the Persian developer community
