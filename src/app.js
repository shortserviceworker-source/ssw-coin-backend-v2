const express=require('express'),helmet=require('helmet'),cors=require('cors'),rateLimit=require('express-rate-limit');
const auth=require('./routes/auth'),admin=require('./routes/admin'),user=require('./routes/user');
const adminExtra=require('./routes/admin_extra'),userExtra=require('./routes/user_extra'),adminSecurity=require('./routes/admin_security'),publicRoutes=require('./routes/public');
const {requireAuth,requireAdmin}=require('./middleware/auth');
const app=express();app.disable('x-powered-by');app.use(helmet());
const origins=(process.env.CORS_ORIGIN||'').split(',').map(x=>x.trim()).filter(Boolean);
app.use(cors({origin:(origin,cb)=>{if(!origin||origins.includes(origin))return cb(null,true);cb(new Error('Origin not allowed by CORS'));},credentials:false}));
app.use(express.json({limit:'32kb'}));app.use(rateLimit({windowMs:15*60*1000,limit:200,standardHeaders:true,legacyHeaders:false}));
app.get('/health',(_req,res)=>res.json({ok:true,service:'ssw-coin-api',version:'1.2.0'}));
const authLimiter=rateLimit({windowMs:15*60*1000,limit:12,standardHeaders:true,legacyHeaders:false});
app.use('/api/auth',authLimiter,auth);app.use('/api/public',publicRoutes);
app.use('/api/user',requireAuth,async(req,res,next)=>{try{const q=await require('./services/db').pool.query('SELECT maintenance_mode,maintenance_enabled,read_only_mode FROM system_controls WHERE id=1');const c=q.rows[0]||{};if(c.maintenance_mode||c.maintenance_enabled)return res.status(503).json({error:'Platform is temporarily in maintenance mode'});if(c.read_only_mode&&!['GET','HEAD','OPTIONS'].includes(req.method))return res.status(403).json({error:'Platform is in read-only mode'});next();}catch(e){next(e)}},user,userExtra);
app.use('/api/admin/security',requireAuth,requireAdmin(),adminSecurity);
app.use('/api/admin',requireAuth);
const routes=[['/summary','dashboard.read'],['/users','users.read'],['/users/:id/status','users.manage'],['/tasks','tasks.read'],['/tasks','tasks.manage'],['/settings/tasks','settings.manage'],['/settings/referrals','settings.manage'],['/settings/rewards','rewards.manage'],['/withdrawals','withdrawals.read'],['/wallet/ledger','wallet.read'],['/notifications','notifications.send'],['/notifications','notifications.read'],['/telegram','telegram.manage'],['/logs','security.read'],['/system','system_controls.manage']];
// Each router handler is protected by a route-specific permission inside this wrapper.
const methods={
 get:{'/reports':'reports.read','/security/overview':'security.read','/security/events':'security.read','/settings/registration':'settings.manage','/summary':'dashboard.read','/users':'users.read','/tasks':'tasks.read','/settings/tasks':'settings.manage','/settings/referrals':'settings.manage','/settings/rewards':'rewards.read','/settings/payments':'payments.manage','/withdrawals':'withdrawals.read','/wallet/ledger':'wallet.read','/notifications':'notifications.read','/telegram':'telegram.manage','/logs':'security.read','/system':'system_controls.manage','/referrals':'referrals.read','/bonus/campaigns':'bonus.read','/bonus/awards':'bonus.read','/support':'support.read','/policies':'policies.manage','/reports/exports':'reports.read','/backups':'backups.manage'},
 post:{'/tasks':'tasks.manage','/notifications':'notifications.send','/bonus/campaigns':'bonus.manage','/bonus/campaigns/:id/calculate':'bonus.manage','/support/:id/reply':'support.reply','/policies':'policies.manage','/reports/exports':'reports.export'},
 put:{'/settings/registration':'settings.manage','/settings/payments/:method':'payments.manage','/settings/tasks':'settings.manage','/settings/referrals':'settings.manage','/settings/rewards':'rewards.manage','/telegram':'telegram.manage','/system':'system_controls.manage','/backups/schedules/:id':'backups.manage'},
 patch:{'/support/:id':'support.reply','/users/:id/status':'users.manage','/tasks/:id':'tasks.manage','/referrals/:id/review':'referrals.review'},
 delete:{'/tasks/:id':'tasks.manage'}
};
function permissionFor(method,path){
 const direct=methods[method]?.[path];if(direct)return direct;
 const rules=[
  [/^\/users\/\d+\/status$/,'users.manage','patch'],[/^\/tasks\/\d+$/,'tasks.manage',['patch','delete']],
  [/^\/referrals\/\d+\/review$/,'referrals.review','patch'],[/^\/bonus\/campaigns\/\d+\/calculate$/,'bonus.manage','post'],
  [/^\/support\/\d+$/,'support.read','get'],[/^\/support\/\d+$/,'support.reply','patch'],[/^\/bonus\/campaigns\/\d+\/leaderboard$/,'bonus.read','get'],[/^\/support\/\d+\/reply$/,'support.reply','post'],
  [/^\/policies\/\d+\/publish$/,'policies.manage','post']
 ];for(const [re,perm,m] of rules){if(re.test(path)&&(Array.isArray(m)?m.includes(method):m===method))return perm;}return null;
}
app.use('/api/admin',(req,res,next)=>{const perm=permissionFor(req.method.toLowerCase(),req.path);if(!perm)return res.status(404).json({error:'API route not available in v1.2'});return requireAdmin(perm)(req,res,next);},admin,adminExtra);
app.use((err,_req,res,_next)=>{console.error(err.message);res.status(err.status||500).json({error:process.env.NODE_ENV==='production'?'Request failed':err.message});});
module.exports=app;
