# Perl Ecommerce Platform

A complete, production-ready ecommerce web application built with Perl using the Mojolicious framework.

## Features

✅ **User Management**
- User registration and authentication
- SHA256 password hashing
- Session management
- Admin role support

✅ **Product Catalog**
- Product listing with search
- Category filtering
- Product details page
- Stock management

✅ **Shopping Cart**
- Add/remove items from cart
- View cart
- Cart persistence per user

✅ **Checkout & Orders**
- Complete checkout process
- Order creation and management
- Order history tracking
- Order status updates

✅ **Admin Dashboard**
- Product management (add/edit/delete)
- Order management
- User management
- Dashboard with statistics

## Tech Stack

- **Framework**: Mojolicious::Lite
- **Database**: SQLite3
- **Authentication**: SHA256 hashing
- **Language**: Perl 5.10+

## Installation

### Prerequisites

```bash
# Install Perl modules
cpan Mojolicious
cpan DBD::SQLite
cpan JSON::PP
```

Or using cpanminus:

```bash
cpanm Mojolicious DBD::SQLite JSON::PP
```

### Setup

1. Clone the repository:
```bash
git clone https://github.com/vipingit1/perlWebProject1.git
cd perlWebProject1
```

2. Run the application:
```bash
perl app.pl daemon -l http://*:3000
```

3. Open your browser and visit:
```
http://localhost:3000
```

## Usage

### First Time Setup

1. **Create Admin User** (optional)
   - Register a normal account first
   - Use SQLite to set `is_admin = 1` for your user:
   ```bash
   sqlite3 ecommerce.db "UPDATE users SET is_admin = 1 WHERE username = 'your_admin_username';"
   ```

2. **Add Products**
   - Login as admin
   - Go to `/admin`
   - Add products with name, description, price, stock, category

### User Workflow

1. **Browse Products**: Visit `/products` to see all products
2. **View Details**: Click on a product to see full details
3. **Add to Cart**: Add products to your shopping cart
4. **Checkout**: Go to `/cart` and proceed to checkout
5. **View Orders**: Check your order history

### Admin Workflow

1. **Dashboard**: Visit `/admin` to see statistics
2. **Manage Products**: Add, edit, or delete products
3. **Manage Orders**: View and update order statuses

## Database Schema

### Users Table
```sql
CREATE TABLE users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    email TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    full_name TEXT,
    phone TEXT,
    address TEXT,
    city TEXT,
    postal_code TEXT,
    is_admin INTEGER DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

### Products Table
```sql
CREATE TABLE products (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    description TEXT,
    price REAL NOT NULL,
    stock INTEGER DEFAULT 0,
    category TEXT,
    image_url TEXT,
    sku TEXT UNIQUE,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

### Orders Table
```sql
CREATE TABLE orders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    total_price REAL NOT NULL,
    status TEXT DEFAULT 'pending',
    shipping_address TEXT,
    payment_method TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
);
```

## API Routes

### Authentication
- `GET /login` - Login page
- `POST /login` - Submit login
- `GET /register` - Registration page
- `POST /register` - Submit registration
- `GET /logout` - Logout user

### Public Routes
- `GET /` - Home page
- `GET /products` - Product listing
- `GET /product/:id` - Product details

### User Routes (Authenticated)
- `GET /cart` - View shopping cart
- `POST /cart/add` - Add item to cart
- `POST /cart/remove/:id` - Remove item from cart
- `POST /checkout` - Process checkout
- `GET /order/:id` - View order details

### Admin Routes (Admin Only)
- `GET /admin` - Admin dashboard
- `GET /admin/products` - Product management
- `GET /admin/product/add` - Add product form
- `POST /admin/product` - Create product
- `GET /admin/product/:id/edit` - Edit product form
- `POST /admin/product/:id` - Update product
- `POST /admin/product/:id/delete` - Delete product
- `GET /admin/orders` - Order management
- `POST /admin/order/:id/status` - Update order status

## Sample Data

To add sample products, use the admin dashboard or run:

```bash
perl sample_data.pl
```

## Configuration

Edit `app.pl` to customize:

- **Secret Key**: Line `app->secrets(['perl-ecommerce-secret-key']);`
- **Database**: Line `DBI->connect('dbi:SQLite:ecommerce.db', ...)` 
- **Port**: Line `perl app.pl daemon -l http://*:3000`

## Troubleshooting

### Database Errors
```bash
# Reset database
rm ecommerce.db

# Run app again to recreate schema
perl app.pl daemon -l http://*:3000
```

### Module Not Found
```bash
# Install missing modules
cpanm --installdeps .
```

### Port Already in Use
```bash
# Change port
perl app.pl daemon -l http://*:8080
```

## Development

### Run in Development Mode
```bash
perl app.pl daemon -w
```

### Run Tests
```bash
perl -I. t/*.t
```

## Security Notes

⚠️ **For Production:**
- Change the secret key in `app->secrets()`
- Use HTTPS/SSL in production
- Add password strength validation
- Implement rate limiting
- Add CSRF token validation
- Use environment variables for sensitive config
- Hash passwords with bcrypt or Argon2 instead of SHA256
- Add input validation and sanitization

## Future Enhancements

- [ ] Payment gateway integration (Stripe, PayPal)
- [ ] Email notifications
- [ ] Product reviews and ratings
- [ ] Wishlist functionality
- [ ] Advanced search with filters
- [ ] User profile management
- [ ] Inventory alerts
- [ ] REST API
- [ ] Mobile app support

## License

MIT License - See LICENSE file for details

## Support

For issues or questions, please open an issue on GitHub.

## Author

Created for learning and demonstration purposes.
