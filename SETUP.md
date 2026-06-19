# Setup Guide - Perl Ecommerce Platform

## Quick Start (5 minutes)

### Step 1: Install Dependencies

```bash
# Using cpanminus (recommended)
cpanm Mojolicious DBD::SQLite JSON::PP

# Or using cpan
cpan Mojolicious
cpan DBD::SQLite
cpan JSON::PP
```

### Step 2: Run the Application

```bash
cd /path/to/perlWebProject1
perl app.pl daemon -l http://*:3000
```

### Step 3: Access the Application

Open your browser and go to: `http://localhost:3000`

---

## Detailed Setup

### Prerequisites

- Perl 5.10 or higher
- SQLite 3
- Git

### Install Perl Modules

#### Option A: Using cpanminus (Recommended)

```bash
# Install cpanminus if not already installed
curl -L https://cpanmin.us | perl - --self-upgrade

# Install required modules
cpanm Mojolicious
cpanm DBD::SQLite
cpanm JSON::PP
```

#### Option B: Using CPAN Shell

```bash
perl -MCPAN -e "install Mojolicious"
perl -MCPAN -e "install DBD::SQLite"
perl -MCPAN -e "install JSON::PP"
```

#### Option C: On Ubuntu/Debian

```bash
sudo apt-get update
sudo apt-get install libmojolicious-perl libdbd-sqlite3-perl libjson-pp-perl
```

#### Option D: On macOS with Homebrew

```bash
brew install perl
cpanm Mojolicious DBD::SQLite JSON::PP
```

### Verify Installation

```bash
# Check Perl version
perl -v

# Check module availability
perl -e "use Mojolicious; print \"Mojolicious OK\\n"
perl -e "use DBD::SQLite; print \"DBD::SQLite OK\\n"
perl -e "use JSON::PP; print \"JSON::PP OK\\n"
```

---

## Running the Application

### Development Mode

```bash
perl app.pl daemon -l http://*:3000
```

With auto-reload on file changes:
```bash
perl app.pl daemon -l http://*:3000 -w
```

### Production Mode

```bash
perl app.pl daemon -l http://*:3000 -a hypnotoad
```

Or using a process manager:

```bash
sudo apt-get install supervisor
# Add to /etc/supervisor/conf.d/ecommerce.conf
[program:ecommerce]
command=perl /path/to/app.pl daemon -l http://*:3000
autostart=true
autorestart=true
user=www-data
```

---

## Database Setup

### Automatic Setup

The database is created automatically on first run. Tables are created with proper schema.

### Manual Database Inspection

```bash
# Check database status
sqlite3 ecommerce.db

# List all tables
.tables

# View table schema
.schema products
.schema users
.schema orders
.schema cart_items
.schema order_items
```

### Reset Database

```bash
# Remove existing database
rm ecommerce.db

# Run app to recreate database
perl app.pl daemon -l http://*:3000
```

---

## Creating Admin User

### Method 1: Using SQLite CLI

```bash
# First, register a normal user via the web interface
# Then, promote them to admin:

sqlite3 ecommerce.db
SQLite version 3.x.x

SQLite> UPDATE users SET is_admin = 1 WHERE username = 'your_username';
SQLite> SELECT id, username, is_admin FROM users;
SQLite> .quit
```

### Method 2: Using Perl Script

Create `admin_setup.pl`:

```perl
#!/usr/bin/perl
use strict;
use warnings;
use DBI;

my $db = DBI->connect('dbi:SQLite:ecommerce.db', '', '', {
    RaiseError => 1,
    AutoCommit => 1
});

my $username = $ARGV[0] || 'admin';

$db->do('UPDATE users SET is_admin = 1 WHERE username = ?', undef, $username);
print "User '$username' is now an admin!\n";
```

Run:
```bash
perl admin_setup.pl your_username
```

---

## Adding Sample Data

### Run Sample Data Script

```bash
perl sample_data.pl
```

This adds sample products in categories: Electronics, Accessories, Clothing, and Books.

---

## Configuration

### Change Port

```bash
# Default port is 3000
perl app.pl daemon -l http://*:8080  # Use port 8080
```

### Change Secret Key (for security)

Edit `app.pl` and find this line:

```perl
app->secrets(['perl-ecommerce-secret-key']);
```

Change to:

```perl
app->secrets(['your-secure-random-secret-key-here']);
```

### Environment Variables

Create `.env` file:

```bash
PORT=3000
DB_PATH=ecommerce.db
SECRET_KEY=your-secret-key
```

---

## Troubleshooting

### "Can't locate Mojolicious.pm"

```bash
# Install missing module
cpanm Mojolicious

# Verify installation
perl -e "use Mojolicious; print \"OK\\n"
```

### "Can't locate DBD/SQLite.pm"

```bash
cpanm DBD::SQLite
```

### Port Already in Use

```bash
# Find process using port 3000
lsof -i :3000

# Kill the process
kill -9 <PID>

# Or use different port
perl app.pl daemon -l http://*:8080
```

### Database Locked

```bash
# Remove lock file
rm ecommerce.db-journal

# Restart application
```

---

## Testing

### Manual Testing

1. **Register**: Go to `/register`
2. **Login**: Go to `/login`
3. **Browse**: Visit `/products`
4. **Add to Cart**: Add items to cart
5. **Checkout**: Complete checkout process
6. **Admin**: Go to `/admin` (if admin)

### Load Testing

```bash
# Using Apache Bench
ab -n 1000 -c 10 http://localhost:3000/

# Using wrk (if installed)
wrk -t4 -c100 -d30s http://localhost:3000/
```

---

## Deployment

### Deploy to VPS

1. Connect to VPS
2. Install dependencies
3. Clone repository
4. Setup database
5. Configure web server (Nginx/Apache)
6. Use process manager (Supervisor/SystemD)

### Nginx Configuration

```nginx
server {
    listen 80;
    server_name yourdomain.com;

    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }
}
```

---

## Next Steps

1. Customize styles and templates
2. Add payment gateway integration
3. Setup email notifications
4. Configure SSL/HTTPS
5. Setup backup strategy
6. Monitor performance

---

For more help, check the main README.md file.
