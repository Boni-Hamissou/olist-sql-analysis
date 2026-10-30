/* =====================================================================
   01 - IMPORT ET NETTOYAGE DE LA BASE OLIST
   ---------------------------------------------------------------------
   Base : olist (SQL Server Express, SSMS)
   Données : 8 fichiers CSV Olist importés avec "Importer un fichier plat".
   La table geolocation n'est pas importée : la ville et l'État figurent
   déjà dans customers et sellers, elle n'est pas utile aux analyses.

   Objectif de ce script : s'assurer que les données importées sont
   fiables AVANT de les analyser. Il est rejouable : on peut le relancer
   en entier sans erreur, même si les corrections ont déjà été faites.
   ===================================================================== */


/* ---------------------------------------------------------------------
   1. Contrôle de l'import : nombre de lignes de chaque table
   ---------------------------------------------------------------------
   Pourquoi : vérifier qu'aucune ligne n'a été perdue ou ajoutée à
   l'import. Comment lire : comparer chaque nombre au nombre de lignes du
   fichier CSV correspondant (en-tête exclu). Un écart d'une ligne signale
   souvent un en-tête importé comme une donnée.

   sys.tables liste les tables, sys.partitions donne leur nombre de lignes.
   Le filtre index_id IN (0,1) évite de compter plusieurs fois les lignes
   quand une table possède des index supplémentaires.
   --------------------------------------------------------------------- */
SELECT t.name AS table_nom, SUM(p.rows) AS nb_lignes
FROM sys.tables t
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
GROUP BY t.name
ORDER BY t.name;


/* ---------------------------------------------------------------------
   2. Correction des types de colonnes
   ---------------------------------------------------------------------
   L'assistant d'import devine les types en lisant seulement les premières
   lignes, ce qui peut donner de mauvais choix. Il faut donc contrôler les
   types (étape 4) et corriger ce qui doit l'être.

   a) price, freight_value, payment_value : ce sont des montants, ils
      doivent être des nombres décimaux. En texte (varchar), SQL Server
      refuserait les SUM / AVG, ou trierait "1000" avant "99".
   b) product_weight_g : le type smallint s'arrête à 32 767. Un poids plus
      grand fait échouer l'import. On utilise INT, plus large.
   --------------------------------------------------------------------- */
ALTER TABLE order_items    ALTER COLUMN price            DECIMAL(10,2);
ALTER TABLE order_items    ALTER COLUMN freight_value    DECIMAL(10,2);
ALTER TABLE order_payments ALTER COLUMN payment_value    DECIMAL(10,2) NULL;
ALTER TABLE products       ALTER COLUMN product_weight_g INT NULL;


/* ---------------------------------------------------------------------
   3. Nettoyage de la table de traduction des catégories
   ---------------------------------------------------------------------
   Anomalie à corriger : l'import a pris la ligne d'en-tête du fichier pour
   une donnée et nommé les colonnes column1 / column2.

   Le bloc IF ne s'exécute que si column1 existe encore : c'est ce qui rend
   le script rejouable. Le DELETE est écrit dans un EXEC('...') : sans cela,
   SQL Server vérifie le nom de colonne avant d'exécuter le script et le
   refuse dès que column1 a été renommée.
   --------------------------------------------------------------------- */
IF COL_LENGTH('product_category_name_translation', 'column1') IS NOT NULL
BEGIN
    -- Supprime la ligne d'en-tête importée comme une donnée
    EXEC('DELETE FROM product_category_name_translation
          WHERE column1 = ''product_category_name''');
    -- Renomme les colonnes pour que les jointures soient lisibles
    EXEC sp_rename 'product_category_name_translation.column1', 'product_category_name',         'COLUMN';
    EXEC sp_rename 'product_category_name_translation.column2', 'product_category_name_english', 'COLUMN';
END

-- Contrôles : le total doit être celui du fichier source (en-tête exclu),
-- et les premières lignes doivent être de vraies catégories, pas un en-tête.
SELECT COUNT(*) AS nb_lignes FROM product_category_name_translation;
SELECT TOP 5 * FROM product_category_name_translation;


/* ---------------------------------------------------------------------
   4. Contrôle des types après correction
   ---------------------------------------------------------------------
   Comment lire : price, freight_value et payment_value doivent être de
   type decimal ; review_score un petit entier (tinyint) ; les colonnes de
   date de type datetime2. Un montant resté en varchar signale une
   conversion à refaire.
   --------------------------------------------------------------------- */
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE COLUMN_NAME IN ('price','freight_value','payment_value','review_score',
                      'order_purchase_timestamp','shipping_limit_date')
ORDER BY TABLE_NAME;


/* ---------------------------------------------------------------------
   5. Contrôle des totaux après conversion
   ---------------------------------------------------------------------
   Pourquoi : une conversion de type peut arrondir ou tronquer des valeurs
   sans erreur visible. On calcule les totaux (toutes commandes, tous
   statuts) et on les compare à la somme de la même colonne calculée
   indépendamment sur le fichier CSV (tableur, Python...).
   Comment lire : les deux sommes doivent être identiques au centime.
   --------------------------------------------------------------------- */
SELECT SUM(price) AS ca_articles, SUM(freight_value) AS total_frais, COUNT(*) AS nb_lignes
FROM order_items;

SELECT SUM(payment_value) AS total_paiements, COUNT(*) AS nb_lignes
FROM order_payments;


/* ---------------------------------------------------------------------
   6. Périmètre des analyses : les commandes livrées
   ---------------------------------------------------------------------
   Toutes les analyses suivantes ne gardent que order_status = 'delivered',
   pour exclure les commandes annulées, indisponibles ou encore en cours.

   Cette requête donne la taille du périmètre : le nombre de commandes
   livrées et leur chiffre d'affaires (CA = somme des prix, hors frais de
   port). Comparer ce CA à celui de l'étape 5 mesure le poids des commandes
   non livrées, qu'on choisit d'écarter.
   --------------------------------------------------------------------- */
SELECT COUNT(DISTINCT o.order_id) AS nb_commandes_livrees,
       SUM(oi.price)              AS ca_livre
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.order_status = 'delivered';

/* =====================================================================
   02 - ÉVOLUTION MENSUELLE DU CHIFFRE D'AFFAIRES (CA)
   ---------------------------------------------------------------------
   Question : comment les ventes évoluent-elles au fil du temps ?
   Définitions :
     - CA = somme des prix des articles (price), hors frais de port
     - Panier moyen = CA / nombre de commandes
   Périmètre : commandes livrées uniquement.
   ===================================================================== */

/* ---------------------------------------------------------------------
   Une ligne par mois : nombre de commandes, CA et panier moyen.

   Comment la requête fonctionne :
   - FORMAT(..., 'yyyy-MM') transforme la date d'achat en mois (ex. 2017-11),
     ce qui permet de regrouper les achats par mois.
   - Une commande contient souvent plusieurs lignes d'articles :
     COUNT(DISTINCT order_id) la compte une seule fois.
   - SUM(price) additionne tous les articles du mois.
   - Le panier moyen est le CA divisé par le nombre de commandes.

   Comment lire le résultat :
   - Observer la tendance du CA et du nombre de commandes d'un mois à
     l'autre : croissance, plateau, pics ponctuels.
   - Comparer l'évolution du panier moyen à celle du nombre de commandes :
     si le CA monte alors que le panier reste stable, la croissance vient
     du volume de commandes, pas de commandes plus chères.
   - Repérer les mois à très peu de commandes (début et fin de la période) :
     ils peuvent venir d'un jeu de données incomplet et non d'une vraie
     baisse d'activité. À vérifier avant de les interpréter.
   - La somme de ca_articles sur tous les mois doit être égale au CA livré
     du contrôle de 01_import_et_nettoyage.sql (étape 6).
   --------------------------------------------------------------------- */
SELECT
    FORMAT(o.order_purchase_timestamp, 'yyyy-MM')              AS mois,
    COUNT(DISTINCT o.order_id)                                 AS nb_commandes,
    SUM(oi.price)                                              AS ca_articles,
    ROUND(SUM(oi.price) / COUNT(DISTINCT o.order_id), 2)       AS panier_moyen
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.order_status = 'delivered'
GROUP BY FORMAT(o.order_purchase_timestamp, 'yyyy-MM')
ORDER BY mois;

/* =====================================================================
   03 - CATÉGORIES DE PRODUITS : LESQUELLES RAPPORTENT LE PLUS ?
   ---------------------------------------------------------------------
   Question : quelles catégories génèrent le plus de chiffre d'affaires
   (CA), et sont-elles concentrées ou diversifiées ?
   Définition : CA = somme des prix des articles, hors frais de port.
   Périmètre : commandes livrées uniquement.
   ===================================================================== */

/* ---------------------------------------------------------------------
   Top 10 des catégories : commandes, CA, part du CA total, CA par commande.

   Comment la requête fonctionne :
   - Les noms de catégories sont en portugais : la table de traduction donne
     l'équivalent anglais.
   - LEFT JOIN (et non JOIN) sur cette table : un produit sans catégorie
     traduite garde ses ventes dans le résultat au lieu de disparaître.
   - COALESCE choisit le premier nom disponible : anglais, sinon portugais,
     sinon 'non renseignée'.
   - SUM(SUM(price)) OVER () calcule le CA de toutes les catégories ; la part
     de chaque catégorie est donc rapportée au total, pas au top 10 (la
     fonction de fenêtre est évaluée avant le TOP).
   - ca_par_commande = CA / nombre de commandes de la catégorie.

   Comment lire le résultat :
   - Additionner part_ca_pct sur les 10 lignes donne le poids du top 10 :
     proche de 100 %, les ventes sont concentrées ; plus bas, elles sont
     diversifiées. Regarder aussi le poids de la première catégorie seule.
   - Comparer nb_commandes et ca_par_commande : une catégorie très
     commandée mais à petit panier ne se classe pas comme une catégorie
     moins commandée mais plus chère. Le CA dépend des deux.
   - nb_commandes ne s'additionne pas d'une catégorie à l'autre : une même
     commande peut contenir des articles de plusieurs catégories.
   --------------------------------------------------------------------- */
SELECT TOP 10
    COALESCE(t.product_category_name_english, p.product_category_name, 'non renseignée') AS categorie,
    COUNT(DISTINCT o.order_id)                                  AS nb_commandes,
    SUM(oi.price)                                               AS ca_articles,
    ROUND(100.0 * SUM(oi.price) / SUM(SUM(oi.price)) OVER (), 1) AS part_ca_pct,
    ROUND(SUM(oi.price) / COUNT(DISTINCT o.order_id), 2)        AS ca_par_commande
FROM order_items oi
JOIN orders   o ON o.order_id   = oi.order_id
JOIN products p ON p.product_id = oi.product_id
LEFT JOIN product_category_name_translation t
       ON t.product_category_name = p.product_category_name
WHERE o.order_status = 'delivered'
GROUP BY COALESCE(t.product_category_name_english, p.product_category_name, 'non renseignée')
ORDER BY ca_articles DESC;

/* =====================================================================
   04 - DÉLAIS DE LIVRAISON ET RETARDS
   ---------------------------------------------------------------------
   Questions : les livraisons sont-elles rapides ? La date promise au
   client est-elle respectée ? Y a-t-il des différences selon l'État ou
   selon la période ?

   Définitions :
     - Délai réel  = livraison au client - achat
     - Délai prévu = date de livraison estimée - achat
     - Retard      = livraison APRÈS la date estimée
   Périmètre : commandes livrées dont la date de livraison est renseignée
   (IS NOT NULL) : sans cette date, on ne peut pas calculer de délai.

   Astuce : DATEDIFF(SECOND, ...) / 86400.0 donne des jours avec décimales
   (86 400 secondes = 1 jour). DATEDIFF(DAY, ...) ne compterait que des
   jours entiers, moins précis.
   ===================================================================== */


/* ---------------------------------------------------------------------
   4a. Vue d'ensemble

   Comment lire le résultat :
   - Comparer delai_reel_jours et delai_prevu_jours : l'écart moyen est la
     marge que la plateforme annonce au client. Une grande marge réduit
     mécaniquement le taux de retard.
   - pct_retard = nb_retards / nb_commandes_livrees. Il doit être lu avec
     l'écart ci-dessus : un faible taux de retard ne dit pas que la
     livraison est rapide, seulement qu'elle respecte la date annoncée.
   --------------------------------------------------------------------- */
SELECT COUNT(*) AS nb_commandes_livrees,
       ROUND(AVG(DATEDIFF(SECOND, order_purchase_timestamp, order_delivered_customer_date) / 86400.0), 2) AS delai_reel_jours,
       ROUND(AVG(DATEDIFF(SECOND, order_purchase_timestamp, order_estimated_delivery_date) / 86400.0), 2) AS delai_prevu_jours,
       SUM(CASE WHEN order_delivered_customer_date > order_estimated_delivery_date THEN 1 ELSE 0 END) AS nb_retards,
       ROUND(100.0 * SUM(CASE WHEN order_delivered_customer_date > order_estimated_delivery_date THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_retard
FROM orders
WHERE order_status = 'delivered' AND order_delivered_customer_date IS NOT NULL;


/* ---------------------------------------------------------------------
   4b. Par État du client (classé du plus lent au plus rapide)

   Comment lire le résultat :
   - Ne pas confondre délai long et retard : un État peut avoir un délai
     réel long mais peu de retards si la date estimée y est aussi plus
     large. Comparer les deux colonnes État par État.
   - Regarder nb_commandes avant d'interpréter un pourcentage : sur un État
     avec peu de commandes, quelques retards suffisent à faire varier
     fortement le pourcentage. Ces valeurs sont fragiles.
   - Rapprocher le classement des délais de la distance géographique entre
     l'État et les vendeurs (voir 06_geographie_vendeurs.sql).
   --------------------------------------------------------------------- */
SELECT c.customer_state AS etat,
       COUNT(*) AS nb_commandes,
       ROUND(AVG(DATEDIFF(SECOND, o.order_purchase_timestamp, o.order_delivered_customer_date) / 86400.0), 2) AS delai_reel_jours,
       ROUND(100.0 * SUM(CASE WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_retard
FROM orders o
JOIN customers c ON c.customer_id = o.customer_id
WHERE o.order_status = 'delivered' AND o.order_delivered_customer_date IS NOT NULL
GROUP BY c.customer_state
ORDER BY delai_reel_jours DESC;


/* ---------------------------------------------------------------------
   4c. Évolution du % de retard par mois d'achat

   Comment lire le résultat :
   - Chercher le niveau habituel de retard, puis les mois qui s'en écartent
     nettement. Rapprocher ces mois des pics de commandes vus dans
     02_ca_mensuel.sql : un afflux de commandes met-il la logistique sous
     tension ?
   - Ignorer les mois avec une ou deux commandes : le pourcentage n'y veut
     rien dire (0 % ou 100 % selon une seule commande).
   - Les données ne donnent pas la cause d'un pic : on le constate, on ne
     l'explique pas sans autre source.
   --------------------------------------------------------------------- */
SELECT FORMAT(order_purchase_timestamp, 'yyyy-MM') AS mois,
       COUNT(*) AS nb_commandes,
       ROUND(100.0 * SUM(CASE WHEN order_delivered_customer_date > order_estimated_delivery_date THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_retard
FROM orders
WHERE order_status = 'delivered' AND order_delivered_customer_date IS NOT NULL
GROUP BY FORMAT(order_purchase_timestamp, 'yyyy-MM')
ORDER BY mois;


/* =====================================================================
   05 - SATISFACTION CLIENT ET RETARDS DE LIVRAISON
   ---------------------------------------------------------------------
   Question : un retard de livraison est-il associé à une baisse de la
   note donnée par le client ?
   Périmètre : commandes livrées, avec date de livraison, et ayant au
   moins un avis (une commande sans avis n'a pas de note à analyser).

   Technique : les CTE (WITH ... AS) sont des "sous-requêtes nommées" qui
   découpent le calcul en étapes lisibles.

   Précaution d'interprétation : on mesure une association entre retard et
   note, pas une cause. D'autres facteurs (qualité du produit, par exemple)
   peuvent jouer en même temps.
   ===================================================================== */


/* ---------------------------------------------------------------------
   5a. Note moyenne : commandes à temps contre commandes en retard

   Comment la requête fonctionne :
   - Étape 1 (note_commande) : une commande peut avoir plusieurs avis. On
     calcule la note moyenne PAR COMMANDE pour que chaque commande compte
     une fois. CAST(... AS FLOAT) évite une moyenne arrondie à l'entier,
     car review_score est un petit entier (tinyint).
   - Étape 2 (base) : on associe à chaque commande son statut de livraison
     ('En retard' si livrée après la date estimée, sinon 'A temps').
   - Étape 3 : on calcule la moyenne des notes par statut.

   Comment lire le résultat : comparer note_moyenne entre les deux lignes,
   et regarder nb_commandes pour juger de la taille de chaque groupe.
   --------------------------------------------------------------------- */
WITH note_commande AS (
    SELECT order_id, AVG(CAST(review_score AS FLOAT)) AS note
    FROM order_reviews
    GROUP BY order_id
),
base AS (
    SELECT n.note,
           CASE WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date
                THEN 'En retard' ELSE 'A temps' END AS statut_livraison
    FROM orders o
    JOIN note_commande n ON n.order_id = o.order_id
    WHERE o.order_status = 'delivered' AND o.order_delivered_customer_date IS NOT NULL
)
SELECT statut_livraison, COUNT(*) AS nb_commandes, ROUND(AVG(note), 2) AS note_moyenne
FROM base
GROUP BY statut_livraison;


/* ---------------------------------------------------------------------
   5b. Note moyenne selon la durée du retard

   Pourquoi : le « en retard / à temps » de 5a cache des situations très
   différentes (un jour de retard n'est pas trois semaines de retard).
   On découpe donc le retard en tranches.

   Comment la requête fonctionne :
   - Le CASE calcule l'écart en jours entre la livraison réelle et la date
     estimée (négatif ou nul = à temps ou en avance) et le range dans une
     tranche.
   - Les chiffres devant les libellés ("1 - ", "2 - ") servent à trier les
     tranches dans le bon ordre avec ORDER BY.

   Comment lire le résultat : suivre la note de tranche en tranche. Où
   baisse-t-elle le plus vite ? Se stabilise-t-elle à partir d'un certain
   retard ? Regarder nb_commandes de chaque tranche avant de conclure.
   --------------------------------------------------------------------- */
WITH note_commande AS (
    SELECT order_id, AVG(CAST(review_score AS FLOAT)) AS note
    FROM order_reviews
    GROUP BY order_id
),
base AS (
    SELECT n.note,
           CASE
               WHEN DATEDIFF(SECOND, o.order_estimated_delivery_date, o.order_delivered_customer_date) / 86400.0 <= 0  THEN '1 - A temps'
               WHEN DATEDIFF(SECOND, o.order_estimated_delivery_date, o.order_delivered_customer_date) / 86400.0 <= 3  THEN '2 - Retard 0 a 3 j'
               WHEN DATEDIFF(SECOND, o.order_estimated_delivery_date, o.order_delivered_customer_date) / 86400.0 <= 7  THEN '3 - Retard 3 a 7 j'
               WHEN DATEDIFF(SECOND, o.order_estimated_delivery_date, o.order_delivered_customer_date) / 86400.0 <= 14 THEN '4 - Retard 7 a 14 j'
               ELSE '5 - Retard > 14 j'
           END AS tranche
    FROM orders o
    JOIN note_commande n ON n.order_id = o.order_id
    WHERE o.order_status = 'delivered' AND o.order_delivered_customer_date IS NOT NULL
)
SELECT tranche, COUNT(*) AS nb_commandes, ROUND(AVG(note), 2) AS note_moyenne
FROM base
GROUP BY tranche
ORDER BY tranche;


/* ---------------------------------------------------------------------
   5c. Note moyenne globale et nombre de commandes notées

   Pourquoi : donne le point de repère général pour situer les notes de 5a
   et 5b, et sert de contrôle croisé avec la mesure « Note moyenne » du
   tableau de bord Power BI (les deux doivent être identiques).
   Le nombre de commandes est aussi plus petit que celui de 04_livraison.sql :
   les commandes sans avis ne sont pas comptées ici.
   --------------------------------------------------------------------- */
WITH note_commande AS (
    SELECT order_id, AVG(CAST(review_score AS FLOAT)) AS note
    FROM order_reviews
    GROUP BY order_id
)
SELECT COUNT(*) AS nb_commandes, ROUND(AVG(n.note), 2) AS note_moyenne
FROM orders o
JOIN note_commande n ON n.order_id = o.order_id
WHERE o.order_status = 'delivered' AND o.order_delivered_customer_date IS NOT NULL;

/* =====================================================================
   06 - GÉOGRAPHIE ET VENDEURS
   ---------------------------------------------------------------------
   Questions : d'où viennent les clients et le CA ? Les vendeurs sont-ils
   répartis comme les clients ? Les ventes dépendent-elles de quelques
   États ou de quelques vendeurs ?

   Définition : CA = somme des prix des articles, hors frais de port.
   Périmètre : commandes livrées uniquement.

   Précaution : les clients sont comptés avec customer_unique_id. Dans
   Olist, customer_id change à chaque commande : compter customer_id
   compterait plusieurs fois un même client.
   ===================================================================== */


/* ---------------------------------------------------------------------
   6a. Clients, commandes et CA par État du CLIENT (côté demande)

   Comment lire le résultat :
   - Comparer clients_uniques et nb_commandes : un écart faible indique que
     peu de clients commandent plusieurs fois.
   - Regarder la place des premiers États dans le classement et la façon
     dont le CA décroît ensuite. Le calcul de la part des 3 premiers est
     fait en 6b.
   --------------------------------------------------------------------- */
SELECT c.customer_state AS etat,
       COUNT(DISTINCT c.customer_unique_id) AS clients_uniques,
       COUNT(DISTINCT o.order_id) AS nb_commandes,
       ROUND(SUM(i.price), 2) AS ca_articles
FROM orders o
JOIN customers c ON c.customer_id = o.customer_id
JOIN order_items i ON i.order_id = o.order_id
WHERE o.order_status = 'delivered'
GROUP BY c.customer_state
ORDER BY ca_articles DESC;


/* ---------------------------------------------------------------------
   6b. Part du CA des 3 premiers États clients

   Comment la requête fonctionne : la CTE calcule le CA de chaque État ;
   on additionne ensuite les 3 plus grands (TOP 3) et on divise par le CA
   de tous les États.

   Comment lire le résultat : un pourcentage élevé signifie que l'activité
   dépend fortement de quelques États. À comparer avec la concentration des
   vendeurs en 6c.
   --------------------------------------------------------------------- */
WITH ca_etat AS (
    SELECT c.customer_state AS etat, SUM(i.price) AS ca
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    JOIN order_items i ON i.order_id = o.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_state
)
SELECT ROUND(100.0 * SUM(ca) / (SELECT SUM(ca) FROM ca_etat), 1) AS part_top3_pct
FROM (SELECT TOP 3 ca FROM ca_etat ORDER BY ca DESC) AS top3;


/* ---------------------------------------------------------------------
   6c. Vendeurs actifs et CA par État du VENDEUR (côté offre)

   Pourquoi : comparer avec 6a. Les vendeurs sont-ils répartis comme les
   clients, ou concentrés ailleurs ? Un décalage entre les deux peut
   expliquer des écarts de délais de livraison (voir 04_livraison.sql).

   Comment lire le résultat :
   - Regarder le nombre de vendeurs par État : un État avec un seul vendeur
     dépend entièrement de lui.
   - Repérer les États clients (6a) qui n'apparaissent pas ici : ils n'ont
     aucun vendeur local, donc leurs commandes viennent d'autres États.
   --------------------------------------------------------------------- */
SELECT s.seller_state AS etat,
       COUNT(DISTINCT s.seller_id) AS vendeurs_actifs,
       ROUND(SUM(i.price), 2) AS ca_articles
FROM order_items i
JOIN orders o ON o.order_id = i.order_id
JOIN sellers s ON s.seller_id = i.seller_id
WHERE o.order_status = 'delivered'
GROUP BY s.seller_state
ORDER BY ca_articles DESC;


/* ---------------------------------------------------------------------
   6d. Top 10 des vendeurs par CA

   Comment lire le résultat :
   - Regarder l'État de chaque vendeur : sont-ils tous dans le même ?
   - Calculer CA / nb_commandes pour chacun : cela distingue un vendeur à
     fort volume et petit panier d'un vendeur à peu de commandes mais cher.
   --------------------------------------------------------------------- */
SELECT TOP 10 i.seller_id, s.seller_state AS etat,
       COUNT(DISTINCT i.order_id) AS nb_commandes,
       ROUND(SUM(i.price), 2) AS ca_articles
FROM order_items i
JOIN orders o ON o.order_id = i.order_id
JOIN sellers s ON s.seller_id = i.seller_id
WHERE o.order_status = 'delivered'
GROUP BY i.seller_id, s.seller_state
ORDER BY ca_articles DESC;


/* ---------------------------------------------------------------------
   6e. Part du CA des 10 premiers vendeurs

   Comment lire le résultat : un pourcentage faible signifie que le CA est
   réparti sur de nombreux vendeurs ; un pourcentage élevé, que la
   plateforme dépend de quelques-uns. Le résultat de 6d donne le détail de
   ces 10 vendeurs.
   --------------------------------------------------------------------- */
WITH ca_vendeur AS (
    SELECT i.seller_id, SUM(i.price) AS ca
    FROM order_items i
    JOIN orders o ON o.order_id = i.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY i.seller_id
)
SELECT ROUND(100.0 * SUM(ca) / (SELECT SUM(ca) FROM ca_vendeur), 1) AS part_top10_pct
FROM (SELECT TOP 10 ca FROM ca_vendeur ORDER BY ca DESC) AS top10;