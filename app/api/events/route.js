import crypto from 'crypto';
export async function POST(req){
  const raw=await req.text();
  const sig=req.headers.get('x-lms-signature')||'';
  const secret=process.env.N8N_WEBHOOK_SECRET||'';
  if(secret){
    const expected=crypto.createHmac('sha256',secret).update(raw).digest('hex');
    const a=Buffer.from(sig), b=Buffer.from(expected);
    if(a.length!==b.length || !crypto.timingSafeEqual(a,b)) return Response.json({error:'Signature invalide'},{status:401});
  }
  let event; try{event=JSON.parse(raw)}catch{return Response.json({error:'JSON invalide'},{status:400})}
  return Response.json({accepted:true,event});
}