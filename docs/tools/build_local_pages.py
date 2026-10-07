#!/usr/bin/env python3
"""Génère les pages statiques de référencement local HAYEVA.

Chaque page est un fichier <slug>/index.html servi tel quel par Netlify
(https://hayeva.fr/<slug>/). Contenu volontairement limité aux faits déjà
publiés sur le site : prestations, zone (Var + Alpes-Maritimes, base à
Fréjus), déplacement offert dans un rayon de 25 km par la route,
téléphone et e-mail de contact. Aucune adresse, aucun SIRET, aucun avis
client, aucun prix susceptible de diverger de la grille en base : les
tarifs restent consultables sur la page d'accueil (#tarifs).

Relancer après modification :  python3 docs/tools/build_local_pages.py
"""
import html
import json
import os
from datetime import date

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
SITE = 'https://hayeva.fr'
PHONE_DISPLAY = '06 71 26 23 02'
PHONE_TEL = '+33671262302'
EMAIL = 'contact@hayeva.fr'
TODAY = date.today().isoformat()
OPENING = "Ouverture le 1er janvier 2027 — premières interventions à partir du 2 janvier 2027."

SERVICES_PART = [
    ('Climatisation', "Entretien de climatisation : démontage, nettoyage complet des filtres et de l'échangeur, remontage."),
    ('Chauffage', "Entretien de chaudière gaz et fioul, dépannage chauffage, remplacement de radiateur, de circulateur ou de vase d'expansion, remise en pression et purge du circuit."),
    ('Plomberie', "Dépannage plomberie, recherche de fuite, débouchage WC, évier et lavabo, remplacement de robinet, de mécanisme WC ou de chasse d'eau, pose de colonne, de paroi ou de receveur de douche, de sèche-serviettes et de baignoire."),
]

PAGES = []

def city(slug, name, h1, intro, local, neighbours):
    PAGES.append(dict(kind='city', slug=slug, name=name, h1=h1, intro=intro, local=local, neighbours=neighbours,
                      title=f"Plombier chauffagiste et climatisation à {name} | HAYEVA",
                      desc=f"Plomberie, chauffage et entretien de climatisation à {name} : réservation en ligne, devis gratuit, compte rendu numérique. HAYEVA, basée à Fréjus."))

city('plombier-chauffagiste-frejus', 'Fréjus',
     'Plombier, chauffagiste et entretien de climatisation à Fréjus',
     "HAYEVA est basée à Fréjus. Nous intervenons chez les particuliers et les professionnels de toute la commune, de Fréjus centre à Saint-Aygulf en passant par Port-Fréjus et Fréjus-Plage.",
     ["Déplacement offert dans un rayon de 25 km par la route autour de HAYEVA : la distance est calculée sur l'itinéraire réel jusqu'à votre adresse exacte, et les frais éventuels sont toujours affichés avant confirmation.",
      "Résidences principales, résidences secondaires et locations saisonnières : nous préparons vos équipements avant la saison (climatisation au printemps, chauffage à l'automne) et intervenons en cas de panne.",
      "Chaque intervention donne lieu à un compte rendu numérique, archivé dans votre espace client HAYEVA."],
     ['Saint-Raphaël', 'Puget-sur-Argens', 'Roquebrune-sur-Argens', 'Le Muy'])

city('plombier-chauffagiste-saint-raphael', 'Saint-Raphaël',
     'Plombier, chauffagiste et entretien de climatisation à Saint-Raphaël',
     "Depuis notre base de Fréjus, nous intervenons à Saint-Raphaël, de Boulouris à Agay et Anthéor, pour l'entretien et le dépannage de vos équipements de plomberie, de chauffage et de climatisation.",
     ["Saint-Raphaël est limitrophe de Fréjus : le déplacement est offert dès lors que votre adresse est à moins de 25 km par la route de HAYEVA. Si des frais s'appliquent, ils sont toujours affichés avant la validation de votre demande.",
      "Appartements, villas, résidences secondaires et locations de vacances : réservez un créneau en ligne et retrouvez vos comptes rendus, devis et factures dans votre espace client.",
      "Pour les conciergeries et gestionnaires de plusieurs logements, nos Checks techniques bénéficient d'un tarif dégressif."],
     ['Fréjus', 'Le Muy', 'Var'])

city('plombier-chauffagiste-le-muy', 'Le Muy',
     'Plombier, chauffagiste et entretien de climatisation au Muy',
     "Nous intervenons au Muy et dans les communes voisines de la vallée de l'Argens pour l'entretien de chaudière, le dépannage chauffage, la plomberie et l'entretien de climatisation.",
     ["Le déplacement est offert dans un rayon de 25 km par la route autour de HAYEVA. Le montant éventuel est calculé sur l'itinéraire réel jusqu'à votre adresse exacte et toujours affiché avant confirmation.",
      "Maisons individuelles, chaudières gaz ou fioul, climatiseurs muraux : un seul interlocuteur pour l'entretien annuel et les dépannages.",
      "Vous recevez un rappel lorsque l'entretien de vos équipements approche."],
     ['Fréjus', 'Saint-Raphaël', 'Var'])

city('plombier-chauffagiste-puget-sur-argens', 'Puget-sur-Argens',
     'Plombier, chauffagiste et entretien de climatisation à Puget-sur-Argens',
     "Puget-sur-Argens est voisine de Fréjus, où HAYEVA est basée. Nous y intervenons pour l'entretien et le dépannage de vos équipements de plomberie, de chauffage et de climatisation.",
     ["Déplacement offert dans un rayon de 25 km par la route autour de HAYEVA : la distance est calculée sur l'itinéraire réel jusqu'à votre adresse exacte, et les frais éventuels sont toujours affichés avant confirmation.",
      "Maisons, appartements et résidences secondaires : entretien annuel de chaudière et de climatisation, dépannage plomberie et chauffage.",
      "Rappel automatique la veille de votre rendez-vous et compte rendu numérique après l'intervention."],
     ['Fréjus', 'Roquebrune-sur-Argens', 'Le Muy', 'Var'])

city('plombier-chauffagiste-roquebrune-sur-argens', 'Roquebrune-sur-Argens',
     'Plombier, chauffagiste et entretien de climatisation à Roquebrune-sur-Argens',
     "Nous intervenons à Roquebrune-sur-Argens, du village aux Issambres en passant par La Bouverie, pour l'entretien et le dépannage de vos équipements.",
     ["Déplacement offert dans un rayon de 25 km par la route autour de HAYEVA : la distance est calculée sur l'itinéraire réel jusqu'à votre adresse exacte, et les frais éventuels sont toujours affichés avant confirmation.",
      "Résidences secondaires, locations de vacances et mobil-homes : contrôle des équipements avant la saison et intervention en cas de panne.",
      "Conciergeries et gestionnaires de plusieurs logements : Checks techniques avec tarif dégressif et rapports avec photos."],
     ['Fréjus', 'Puget-sur-Argens', 'Saint-Raphaël', 'Var'])

PAGES.append(dict(kind='city', slug='plombier-chauffagiste-var', name='Var',
     title='Plombier chauffagiste et climatisation dans le Var (83) | HAYEVA',
     desc="Plomberie, chauffage et entretien de climatisation dans tout le Var (83) : Fréjus, Saint-Raphaël, Le Muy, Draguignan, Fayence… Réservation en ligne, devis gratuit.",
     h1='Plomberie, chauffage et climatisation dans tout le Var (83)',
     intro="Basée à Fréjus, HAYEVA intervient dans l'ensemble du département du Var, pour les particuliers comme pour les professionnels.",
     local=["Communes régulièrement desservies : Fréjus, Saint-Raphaël, Puget-sur-Argens, Roquebrune-sur-Argens, Le Muy, Draguignan, Saint-Tropez, Hyères, Toulon, ainsi que l'arrière-pays (Bagnols-en-Forêt, Fayence, Tourrettes, Callian, Montauroux, Saint-Paul-en-Forêt, Seillans, Mons, Bargemon).",
            "Déplacement offert dans un rayon de 25 km par la route autour de HAYEVA. Au-delà, des frais kilométriques peuvent s'appliquer : ils sont calculés sur l'itinéraire réel et toujours indiqués avant confirmation.",
            "Réservation en ligne, confirmation par e-mail, compte rendu numérique après chaque intervention."],
     neighbours=['Fréjus', 'Saint-Raphaël', 'Le Muy', 'Alpes-Maritimes']))

PAGES.append(dict(kind='city', slug='plombier-chauffagiste-alpes-maritimes', name='Alpes-Maritimes',
     title='Plombier chauffagiste et climatisation dans les Alpes-Maritimes (06) | HAYEVA',
     desc="Plomberie, chauffage et entretien de climatisation dans les Alpes-Maritimes (06) : Cannes, Grasse, Antibes, Nice… Réservation en ligne, devis gratuit.",
     h1='Plomberie, chauffage et climatisation dans les Alpes-Maritimes (06)',
     intro="Depuis Fréjus, HAYEVA se déplace dans les Alpes-Maritimes pour l'entretien et le dépannage de vos équipements.",
     local=["Communes desservies : Cannes, Grasse, Antibes, Cagnes-sur-Mer, Villeneuve-Loubet, Nice, Menton, ainsi que les hauteurs (Cabris, Spéracèdes, Saint-Cézaire-sur-Siagne, Saint-Vallier-de-Thiey, Andon, Caille, Séranon, Valderoure).",
            "Les frais de déplacement éventuels sont calculés sur l'itinéraire routier réel jusqu'à votre adresse et affichés avant toute confirmation.",
            "Particuliers, conciergeries, agences et gestionnaires de plusieurs logements : réservation et suivi depuis votre espace en ligne."],
     neighbours=['Var', 'Fréjus', 'Saint-Raphaël']))

PAGES.append(dict(kind='service', slug='entretien-climatisation-frejus-saint-raphael', name='Entretien climatisation',
     title='Entretien de climatisation à Fréjus, Saint-Raphaël et dans le Var | HAYEVA',
     desc="Entretien de climatisation à Fréjus, Saint-Raphaël, Le Muy et dans le Var : nettoyage complet des filtres et de l'échangeur, compte rendu numérique, rappel d'entretien.",
     h1='Entretien de climatisation à Fréjus, Saint-Raphaël et dans le Var',
     intro="Un climatiseur entretenu consomme moins, souffle un air plus sain et tombe moins souvent en panne. HAYEVA réalise l'entretien de vos climatisations, en résidence principale comme en location saisonnière.",
     local=["Démontage, nettoyage complet des filtres et de l'échangeur, puis remontage, directement chez vous.",
            "Photos et compte rendu numérique après l'intervention, archivés dans votre espace client.",
            "Rappel automatique quand l'entretien suivant approche.",
            "Le tarif selon le nombre d'unités est affiché sur la page d'accueil, avant toute réservation."],
     neighbours=['Fréjus', 'Saint-Raphaël', 'Le Muy', 'Var']))

PAGES.append(dict(kind='service', slug='entretien-chaudiere-var', name='Entretien chaudière',
     title='Entretien de chaudière gaz et fioul dans le Var | HAYEVA',
     desc="Entretien annuel de chaudière gaz et fioul à Fréjus, Saint-Raphaël, Le Muy et dans le Var. Dépannage chauffage, attestation d'entretien, rappel automatique.",
     h1="Entretien de chaudière gaz et fioul dans le Var",
     intro="L'entretien annuel de votre chaudière garantit sa sécurité et son rendement. HAYEVA intervient sur les chaudières gaz et fioul à Fréjus, Saint-Raphaël, Le Muy et dans tout le Var.",
     local=["Entretien complet avec contrôles, puis remise d'une attestation d'entretien distincte du compte rendu.",
            "Dépannage chauffage, remplacement de circulateur, de vase d'expansion ou de radiateur, remise en pression et purge du circuit.",
            "Rappel automatique avant l'échéance de votre prochain entretien.",
            "Tarifs affichés sur la page d'accueil avant toute réservation."],
     neighbours=['Fréjus', 'Saint-Raphaël', 'Le Muy', 'Var']))

PAGES.append(dict(kind='service', slug='entretien-mobil-home-var', name='Entretien mobil-home',
     title='Entretien technique de mobil-home dans le Var | HAYEVA',
     desc="Contrôle plomberie, chauffage et climatisation de mobil-home à Fréjus, Roquebrune-sur-Argens, Saint-Raphaël et dans le Var : Check technique avec compte rendu et photos.",
     h1='Entretien technique de mobil-home dans le Var',
     intro="Propriétaires de mobil-home, campings et parcs résidentiels : HAYEVA contrôle l'essentiel de votre hébergement avant la saison ou entre deux séjours.",
     local=["Check Express : fuites apparentes, robinets et mitigeurs, WC, douche, évier, évacuations accessibles, eau chaude, test de la climatisation et du chauffage.",
            "Check Complet et Premium : contrôle plus approfondi, photos des anomalies et compte rendu numérique classant chaque élément en « Fonctionnel », « À surveiller » ou « Intervention recommandée ».",
            "Aucune réparation n'est ajoutée ni facturée automatiquement : vous décidez ensuite d'une intervention ou d'un devis séparé.",
            "Plusieurs hébergements : tarif dégressif automatique, affiché avant toute demande.",
            "Ces contrôles visuels et fonctionnels ne constituent ni une certification officielle, ni un diagnostic réglementaire."],
     neighbours=['Fréjus', 'Roquebrune-sur-Argens', 'Saint-Raphaël', 'Campings et mobil-homes']))

PAGES.append(dict(kind='pro', slug='professionnels', name='Professionnels',
     title='Check technique pour conciergeries et locations saisonnières | HAYEVA Pro',
     desc="Checks techniques plomberie, chauffage et climatisation pour conciergeries, agences, gestionnaires multi-logements et locations saisonnières. Tarif dégressif, rapports avec photos.",
     h1='Conciergeries, agences et gestionnaires de locations',
     intro="Avant l'arrivée de vos voyageurs ou tout au long de la saison, HAYEVA contrôle l'essentiel de vos logements : plomberie, chauffage et climatisation.",
     local=["Trois formules de Check technique : Express, Complet et Premium, avec un compte rendu numérique classant chaque élément en « Fonctionnel », « À surveiller » ou « Intervention recommandée ».",
            "Tarif dégressif automatique selon le nombre de logements, toujours affiché en détail avant toute demande.",
            "Historique par logement, rapports avec photos, tournées techniques et déplacements mutualisés.",
            "Aucune réparation n'est ajoutée ni facturée automatiquement : vous restez libre de demander une intervention ou un devis séparé.",
            "Ces contrôles visuels et fonctionnels ne constituent ni une certification officielle, ni un diagnostic réglementaire."],
     neighbours=['Fréjus', 'Saint-Raphaël', 'Var', 'Alpes-Maritimes']))

PAGES.append(dict(kind='pro', slug='syndics-copropriete', name='Syndics et copropriétés',
     title='Plomberie, chauffage et climatisation pour syndics et copropriétés | HAYEVA',
     desc="Syndics, gestionnaires et copropriétés du Var et des Alpes-Maritimes : interventions plomberie, chauffage et climatisation sur devis, compte rendu numérique, facturation en ligne.",
     h1='Syndics, gestionnaires et copropriétés',
     intro="HAYEVA accompagne les syndics et gestionnaires d'immeubles du Var et des Alpes-Maritimes pour les interventions de plomberie, de chauffage et de climatisation dans les logements gérés.",
     local=["Demande d'intervention ou de devis gratuit en ligne, par téléphone ou par e-mail.",
            "Compte rendu numérique avec photos après chaque passage, devis et factures accessibles depuis l'espace professionnel.",
            "Gestion de plusieurs adresses depuis un seul compte, avec l'historique de chaque logement.",
            "Pour un besoin récurrent ou un volume important, contactez-nous : nous établissons un devis adapté."],
     neighbours=['Fréjus', 'Saint-Raphaël', 'Var', 'Alpes-Maritimes']))

PAGES.append(dict(kind='pro', slug='campings-mobil-homes', name='Campings et mobil-homes',
     title='Check technique campings et mobil-homes dans le Var | HAYEVA',
     desc="Campings, parcs résidentiels et propriétaires de mobil-homes du Var : contrôle plomberie, chauffage et climatisation avant la saison, tarif dégressif, rapports avec photos.",
     h1='Campings, parcs résidentiels et mobil-homes',
     intro="Le littoral de Fréjus et de Saint-Raphaël compte de nombreux campings et parcs de mobil-homes. HAYEVA y réalise les contrôles techniques de début et de cours de saison.",
     local=["Check Express, Complet ou Premium par mobil-home : fuites apparentes, robinetterie, WC, douche, évacuations, eau chaude, climatisation et chauffage.",
            "Tarif dégressif automatique selon le nombre d'hébergements, affiché avant toute demande.",
            "Tournées organisées et déplacements mutualisés pour plusieurs hébergements sur un même site.",
            "Compte rendu par hébergement, avec photos des anomalies et priorisation des interventions."],
     neighbours=['Fréjus', 'Saint-Raphaël', 'Le Muy', 'Var']))

PAGES.append(dict(kind='pro', slug='partenaires', name='Partenaires',
     title='Devenir partenaire HAYEVA | Apporteurs d\'affaires et professionnels',
     desc="Agences immobilières, conciergeries, artisans et apporteurs d'affaires du Var et des Alpes-Maritimes : rejoignez le réseau de partenaires HAYEVA.",
     h1='Devenir partenaire de HAYEVA',
     intro="Agences immobilières, conciergeries, gestionnaires, artisans complémentaires ou apporteurs d'affaires : travaillons ensemble pour proposer à vos clients un service de plomberie, de chauffage et de climatisation fiable.",
     local=["Programme d'apporteurs d'affaires : contactez-nous, votre demande est étudiée par HAYEVA, puis un code personnel vous est attribué.",
            "Une prime n'est validée qu'après intervention terminée et paiement confirmé, selon les conditions publiées du programme.",
            "Professionnels : ouvrez un compte pro pour réserver et suivre les interventions de vos clients ou de vos logements.",
            "Pour toute proposition de partenariat, écrivez-nous ou appelez-nous."],
     neighbours=['Fréjus', 'Saint-Raphaël', 'Var', 'Alpes-Maritimes']))

SLUG_BY_NAME = {p['name']: p['slug'] for p in PAGES}

CSS = """
:root{--ink:#16222C;--ink-soft:#5B6B78;--accent:#E85A12;--accent-deep:#C94400;--sand:#F3F1EC;--line:rgba(20,33,44,.12);--white:#fff}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;font-family:Poppins,system-ui,-apple-system,Segoe UI,Roboto,sans-serif;color:var(--ink);background:var(--white);line-height:1.6}
a{color:var(--accent-deep)}img{max-width:100%;display:block}
.wrap{max-width:1040px;margin:0 auto;padding:0 16px}
header.top{border-bottom:1px solid var(--line);background:var(--white);position:sticky;top:0;z-index:5}
header.top .wrap{display:flex;align-items:center;justify-content:space-between;gap:12px;min-height:64px}
header.top img{height:40px;width:auto}
.btn{display:inline-block;background:var(--accent);color:#fff;text-decoration:none;font-weight:700;padding:12px 22px;border-radius:999px;font-size:15px;text-align:center}
.btn:hover{background:var(--accent-deep)}
.btn.ghost{background:transparent;color:var(--ink);border:1.5px solid var(--ink)}
.btn.sm{padding:9px 16px;font-size:14px}
.hero{background:var(--sand);border-bottom:1px solid var(--line);padding:48px 0 40px}
.eyebrow{font-size:13px;letter-spacing:.08em;text-transform:uppercase;color:var(--accent-deep);font-weight:700;margin:0 0 8px}
h1{font-size:clamp(26px,5vw,40px);line-height:1.15;margin:0 0 14px;font-weight:800}
h2{font-size:clamp(20px,3.4vw,26px);margin:0 0 14px;font-weight:700}
.lead{font-size:17px;color:var(--ink-soft);max-width:720px;margin:0 0 22px}
.ctas{display:flex;flex-wrap:wrap;gap:10px}
.notice{margin:18px 0 0;font-size:14px;font-weight:600;color:var(--ink)}
section.block{padding:40px 0;border-bottom:1px solid var(--line)}
ul.facts{padding-left:20px;margin:0}ul.facts li{margin:0 0 10px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:14px}
.card{border:1px solid var(--line);border-radius:14px;padding:18px;background:var(--white)}
.card h3{margin:0 0 6px;font-size:17px}.card p{margin:0;color:var(--ink-soft);font-size:15px}
.chips{display:flex;flex-wrap:wrap;gap:8px;margin:0;padding:0;list-style:none}
.chips a{display:inline-block;padding:7px 14px;border:1px solid var(--line);border-radius:999px;text-decoration:none;color:var(--ink);font-size:14px;background:var(--white)}
.band{background:var(--ink);color:#fff;padding:36px 0}
.band h2{color:#fff}.band p{color:#C9D2D9;margin:0 0 18px}
.band .btn.ghost{color:#fff;border-color:#fff}
footer{padding:28px 0 40px;font-size:14px;color:var(--ink-soft)}
footer nav{display:flex;flex-wrap:wrap;gap:8px 16px;margin:0 0 14px}
footer a{color:var(--ink-soft)}
@media (max-width:520px){header.top .btn.sm{padding:8px 12px;font-size:13px}.hero{padding:32px 0 28px}}
"""

def e(s):
    return html.escape(s, quote=True)

def jsonld(p):
    url = f"{SITE}/{p['slug']}/"
    provider = {"@type": "HomeAndConstructionBusiness", "name": "HAYEVA", "url": SITE + "/",
                "logo": SITE + "/images/brand/hayeva-logo.png", "telephone": PHONE_TEL, "email": EMAIL,
                "areaServed": ["Fréjus", "Saint-Raphaël", "Puget-sur-Argens", "Roquebrune-sur-Argens", "Le Muy", "Var", "Alpes-Maritimes"]}
    area = p['name'] if p['kind'] == 'city' else ["Fréjus", "Saint-Raphaël", "Le Muy", "Var", "Alpes-Maritimes"]
    graph = [
        {"@type": "Service", "name": p['h1'], "serviceType": "Plomberie, chauffage et climatisation",
         "url": url, "description": p['desc'], "areaServed": area, "provider": provider},
        {"@type": "BreadcrumbList", "itemListElement": [
            {"@type": "ListItem", "position": 1, "name": "Accueil", "item": SITE + "/"},
            {"@type": "ListItem", "position": 2, "name": p['name'], "item": url}]},
    ]
    return json.dumps({"@context": "https://schema.org", "@graph": graph}, ensure_ascii=False, indent=1)

def render(p):
    url = f"{SITE}/{p['slug']}/"
    is_pro = p['kind'] == 'pro'
    primary = ('/#/professionnel', 'Espace professionnel') if is_pro else ('/#rdv', 'Prendre rendez-vous')
    facts = ''.join(f'<li>{e(x)}</li>' for x in p['local'])
    services = ''.join(f'<div class="card"><h3>{e(t)}</h3><p>{e(d)}</p></div>' for t, d in SERVICES_PART)
    near = ''.join(f'<li><a href="/{SLUG_BY_NAME[n]}/">{e(n)}</a></li>' for n in p['neighbours'] if n in SLUG_BY_NAME)
    foot = ''.join(f'<a href="/{q["slug"]}/">{e(q["name"])}</a>' for q in PAGES)
    services_block = '' if is_pro else f'''
<section class="block"><div class="wrap">
<h2>Nos prestations</h2>
<div class="grid">{services}</div>
<p style="margin:16px 0 0"><a href="/#tarifs">Voir les tarifs et réserver</a></p>
</div></section>'''
    return f'''<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{e(p['title'])}</title>
<meta name="description" content="{e(p['desc'])}">
<link rel="canonical" href="{url}">
<meta name="robots" content="index, follow">
<meta name="theme-color" content="#16222C">
<meta property="og:type" content="website">
<meta property="og:site_name" content="HAYEVA">
<meta property="og:locale" content="fr_FR">
<meta property="og:title" content="{e(p['title'])}">
<meta property="og:description" content="{e(p['desc'])}">
<meta property="og:url" content="{url}">
<meta property="og:image" content="{SITE}/images/portal/portal-bg-lg.jpg">
<meta name="twitter:card" content="summary_large_image">
<link rel="icon" href="/images/pwa/icon-192.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Poppins:wght@400;600;700;800&display=swap" rel="stylesheet">
<script type="application/ld+json">
{jsonld(p)}
</script>
<style>{CSS}</style>
</head>
<body>
<header class="top"><div class="wrap">
<a href="/" aria-label="HAYEVA — accueil"><img src="/images/brand/hayeva-logo-sm.png" alt="HAYEVA" width="59" height="40"></a>
<a class="btn sm" href="{primary[0]}">{e(primary[1])}</a>
</div></header>
<main>
<section class="hero"><div class="wrap">
<p class="eyebrow">{'HAYEVA Pro' if is_pro else 'Plomberie · Chauffage · Climatisation'}</p>
<h1>{e(p['h1'])}</h1>
<p class="lead">{e(p['intro'])}</p>
<div class="ctas">
<a class="btn" href="{primary[0]}">{e(primary[1])}</a>
<a class="btn ghost" href="tel:{PHONE_TEL}">Appeler le {PHONE_DISPLAY}</a>
</div>
<p class="notice">{e(OPENING)}</p>
</div></section>
<section class="block"><div class="wrap">
<h2>{'Ce que nous proposons' if is_pro else ('Intervention au Muy' if p['name'] == 'Le Muy' else 'Intervention à ' + e(p['name'])) if p['kind'] == 'city' and p['name'] not in ('Var', 'Alpes-Maritimes') else 'En pratique'}</h2>
<ul class="facts">{facts}</ul>
</div></section>{services_block}
<section class="block"><div class="wrap">
<h2>À proximité</h2>
<ul class="chips">{near}</ul>
</div></section>
<section class="band"><div class="wrap">
<h2>{'Un projet, un parc de logements à suivre ?' if is_pro else 'Une panne, un entretien à prévoir ?'}</h2>
<p>Réservez en ligne avec votre compte HAYEVA, ou contactez-nous par téléphone ou par e-mail. Devis gratuit.</p>
<div class="ctas">
<a class="btn" href="{primary[0]}">{e(primary[1])}</a>
<a class="btn ghost" href="mailto:{EMAIL}">{EMAIL}</a>
</div>
</div></section>
</main>
<footer><div class="wrap">
<nav aria-label="Zones et services">{foot}</nav>
<nav aria-label="Informations légales"><a href="/#legal/mentions">Mentions légales</a><a href="/#legal/cgv">CGV</a><a href="/#legal/confidentialite">Confidentialité</a></nav>
<p>HAYEVA — Climatisation · Chauffage · Plomberie — Fréjus, Var (83) et Alpes-Maritimes (06)</p>
</div></footer>
</body>
</html>
'''

def sitemap():
    urls = [(SITE + '/', '1.0', 'weekly')] + [(f"{SITE}/{p['slug']}/", '0.8', 'monthly') for p in PAGES]
    body = ''.join(f"  <url>\n    <loc>{u}</loc>\n    <lastmod>{TODAY}</lastmod>\n    <changefreq>{c}</changefreq>\n    <priority>{pr}</priority>\n  </url>\n" for u, pr, c in urls)
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!-- HAYEVA — sitemap.xml, généré par docs/tools/build_local_pages.py.\n'
            '     La page d\'accueil est une SPA à ancres (une seule URL) ; les pages\n'
            '     locales et professionnelles sont des fichiers statiques distincts. -->\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + body + '</urlset>\n')

if __name__ == '__main__':
    for p in PAGES:
        d = os.path.join(ROOT, p['slug'])
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, 'index.html'), 'w', encoding='utf-8') as f:
            f.write(render(p))
    with open(os.path.join(ROOT, 'sitemap.xml'), 'w', encoding='utf-8') as f:
        f.write(sitemap())
    print(f"{len(PAGES)} pages générées + sitemap.xml")
