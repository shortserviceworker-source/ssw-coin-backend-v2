require('dotenv').config();
if(!process.env.DATABASE_URL) throw new Error('DATABASE_URL is required');
if(!process.env.JWT_SECRET||process.env.JWT_SECRET.length<64) throw new Error('JWT_SECRET must be at least 64 characters');
const app=require('./app');const {pool}=require('./services/db');
const port=Number(process.env.PORT||4000);
const server=app.listen(port,()=>console.log(`S.S.W COIN API v1.1 listening on port ${port}`));
async function shutdown(){server.close(async()=>{await pool.end();process.exit(0);});}
process.on('SIGTERM',shutdown);process.on('SIGINT',shutdown);
