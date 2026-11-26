# S.S.W COIN — Render Staging প্রস্তুতি v1.4

## এই আপডেটে কী করা হয়েছে
- Render Blueprint (`render.yaml`) যোগ করা হয়েছে।
- Node.js API-এর root directory, build/start command এবং `/health` health check নির্ধারণ করা হয়েছে।
- Database URL, JWT secret, Admin 2FA key এবং SMTP credentials `sync: false` রাখা হয়েছে—কোনো গোপন মান ফাইলে রাখা হয়নি।
- Blogger origin `https://sswcoin.blogspot.com` প্রাথমিক CORS allowlist হিসেবে রাখা হয়েছে।

## এখনো যা করা হয়নি
কোনো Render account/service/database তৈরি বা deploy করা হয়নি। PostgreSQL schema চালানো হয়নি, Admin account তৈরি হয়নি, SMTP live test হয়নি। তাই লগইন এখনো চালু নয়।

## অভিভাবকের সাহায্যে পরবর্তী ধাপ
1. এই ZIP-এর ফাইলগুলো একটি private GitHub repository-তে আপলোড করতে হবে। Repository public করবেন না।
2. Render-এ গিয়ে **New → Blueprint** বেছে private repository connect করতে হবে। `render.yaml` শনাক্ত হলে service configuration review করতে হবে।
3. Render service তৈরি করার আগে billing/plan review করতে হবে। কোনো paid plan বা database তৈরি করবেন না, যদি খরচ ও শর্ত অভিভাবক যাচাই না করেন।
4. PostgreSQL database আলাদাভাবে প্রস্তুত হলে তার connection string Render-এর `DATABASE_URL` secret field-এ বসাতে হবে। সেটি ChatGPT-তে বা কারও সঙ্গে শেয়ার করবেন না।
5. নতুন, খালি database হলে কেবল `Backend_API_v1_2/db/001_schema_v1_4.sql` চালাতে হবে। আগে থেকে database/schema থাকলে থামুন—আগে backup ও developer review দরকার।
6. `JWT_SECRET`-এ অন্তত 64 অক্ষরের random secret এবং `ADMIN_2FA_ENCRYPTION_KEY`-এ 64 hex character-এর key অভিভাবক/বিশ্বস্ত developer server dashboard-এ তৈরি করে বসাবেন। এগুলো চ্যাটে পাঠাবেন না।
7. SMTP credentials না থাকলে email verification/password reset পরীক্ষা হবে না; placeholder value বসিয়ে production deploy করবেন না।
8. Deploy-এর পরে service URL-এর শেষে `/health` খুলে `ok: true` দেখা গেলে শুধু API process চালু হয়েছে বোঝাবে—এতে database/schema, Admin login বা সম্পূর্ণ সিস্টেম যাচাই হয় না।

## নিরাপত্তা সীমা
- এই প্যাকেজটি staging/development-এর জন্য। বাস্তব অর্থ, payout, withdrawal বা reward credit চালু করবেন না।
- Admin account creation/provisioning, database execution, end-to-end tests এবং independent security review এখনো বাকি।
- Password, OTP, JWT, database URL, API key, SMTP password, 2FA key বা recovery code কখনো চ্যাটে পাঠাবেন না।
- Render-এর plan/price ও free-tier শর্ত পরিবর্তিত হতে পারে; deploy-এর আগে বর্তমান billing terms অভিভাবক যাচাই করবেন।
