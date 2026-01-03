<div align="center">

# 🎓 EduCMS
### A Modern Education CMS built with Django & Docker

[🚀 Quick Install](#-quick-install) •
[✨ Features](#-features) •
[🧠 Architecture](#-architecture--tech-stack) •
[⚙️ Management](#️-management--configuration) •
[🔐 Security](#-security-notes) •
[📄 License](#-license)

</div>

---

## 📌 Overview

**EduCMS** is a production-ready **Education CMS / LMS** designed for selling and managing online courses.  
It provides a complete workflow for **users, courses, payments, wallet, invoices, and support tickets**, with a **one-command Docker-based deployment**.

The project focuses on:
- Real-world payment scenarios
- High security
- Fast deployment
- Clean, extensible architecture

---

## ✨ Features

### 👤 User & Authentication System
- Login with **email or username**
- User registration with **dynamic custom fields**
- **Security question** system for password recovery
- User profile management
- Admin-controlled permissions for profile & security editing

### 🎓 Course Management
- Course categories
- Free and paid courses
- Publishing states (draft / published / archived)
- Sections & lessons with video/text content
- Access via purchase, free access, or admin grants

### 💳 Orders & Payments
- Card-to-card payment workflow
- Receipt upload & tracking codes
- Order lifecycle management
- Coupon system (percentage / fixed amount)

### 👛 Wallet System
- Dedicated wallet per user
- Top-up requests with admin approval
- Full transaction history

### 🧾 Invoice System
- Automatic invoice generation
- Unique invoice numbers
- User-accessible invoices

### 🎫 Support Tickets
- User-created tickets
- Threaded replies
- Dashboard integration

### 📊 User Dashboard
- Courses
- Orders
- Wallet
- Tickets

### ⚙️ Admin & Site Settings
- Custom admin panel path
- Branding & theme settings
- Dynamic registration fields
- Navigation & template management

---

## 🧠 Architecture & Tech Stack

- Python 3.12
- Django 5
- MySQL 8
- Docker & Docker Compose
- Nginx
- Gunicorn
- Let’s Encrypt (SSL)

---

## 🚀 Quick Install

```bash
bash <(curl -sSL https://raw.githubusercontent.com/admin6501/EduCMS/refs/heads/main/install.sh)
```

---

## 🌐 After Installation

Website:
```
https://your-domain.com
```

Admin panel:
```
https://your-domain.com/ADMIN_PATH/
```

---

## 🔐 Security Notes

- Custom admin path enforcement
- Hashed security answers
- HTTPS-only cookies
- CSRF & proxy security headers

---

## 📄 License

MIT License
