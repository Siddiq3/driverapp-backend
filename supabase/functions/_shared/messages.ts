// Push notification texts in each supported language.
// Keep keys in sync with the app's languages (en, te, hi).

export type Lang = "en" | "te" | "hi";

type Texts = {
  offerTitle: string;
  offerTitleChosen: string;
  offers: (price: number) => string;
  kmAway: (km: string) => string;
  service: { car_with_driver: string; driver_only: string };
  tripType: { local: string; outstation: string; hourly: string };
  acceptedTitle: string;
  acceptedBody: (name: string) => string;
  yourDriver: string;
  arrivedTitle: string;
  arrivedBody: string;
  completedTitle: string;
  completedBody: string;
  cancelledTitle: string;
  cancelledByCustomer: string;
  cancelledByDriver: string;
};

const en: Texts = {
  offerTitle: "New trip request",
  offerTitleChosen: "A customer chose you!",
  offers: (p) => `Offers ₹${p}`,
  kmAway: (km) => `${km} km away`,
  service: { car_with_driver: "Car + driver", driver_only: "Driver only" },
  tripType: { local: "In town", outstation: "Outstation", hourly: "By hours" },
  acceptedTitle: "Driver found",
  acceptedBody: (n) => `${n} accepted your trip.`,
  yourDriver: "Your driver",
  arrivedTitle: "Your driver has arrived",
  arrivedBody: "Please meet your driver at the pickup point.",
  completedTitle: "Trip completed",
  completedBody: "Please rate your driver. Thank you!",
  cancelledTitle: "Trip cancelled",
  cancelledByCustomer: "The customer cancelled this trip.",
  cancelledByDriver: "Your driver cancelled. Please choose another driver.",
};

const te: Texts = {
  offerTitle: "కొత్త ట్రిప్ రిక్వెస్ట్",
  offerTitleChosen: "ఒక కస్టమర్ మిమ్మల్ని ఎంచుకున్నారు!",
  offers: (p) => `₹${p} ఆఫర్`,
  kmAway: (km) => `${km} కి.మీ. దూరంలో`,
  service: { car_with_driver: "కారు + డ్రైవర్", driver_only: "డ్రైవర్ మాత్రమే" },
  tripType: { local: "ఊరిలో", outstation: "ఊరి బయటకు", hourly: "గంటల లెక్కన" },
  acceptedTitle: "డ్రైవర్ దొరికారు",
  acceptedBody: (n) => `${n} మీ ట్రిప్‌ను అంగీకరించారు.`,
  yourDriver: "మీ డ్రైవర్",
  arrivedTitle: "మీ డ్రైవర్ వచ్చారు",
  arrivedBody: "దయచేసి పికప్ ప్రదేశంలో మీ డ్రైవర్‌ను కలవండి.",
  completedTitle: "ట్రిప్ పూర్తయింది",
  completedBody: "దయచేసి మీ డ్రైవర్‌కు రేటింగ్ ఇవ్వండి. ధన్యవాదాలు!",
  cancelledTitle: "ట్రిప్ రద్దయింది",
  cancelledByCustomer: "కస్టమర్ ఈ ట్రిప్‌ను రద్దు చేశారు.",
  cancelledByDriver: "మీ డ్రైవర్ రద్దు చేశారు. దయచేసి మరో డ్రైవర్‌ను ఎంచుకోండి.",
};

const hi: Texts = {
  offerTitle: "नई ट्रिप रिक्वेस्ट",
  offerTitleChosen: "एक ग्राहक ने आपको चुना!",
  offers: (p) => `₹${p} का ऑफ़र`,
  kmAway: (km) => `${km} किमी दूर`,
  service: { car_with_driver: "कार + ड्राइवर", driver_only: "सिर्फ़ ड्राइवर" },
  tripType: { local: "शहर में", outstation: "शहर से बाहर", hourly: "घंटों के हिसाब से" },
  acceptedTitle: "ड्राइवर मिल गया",
  acceptedBody: (n) => `${n} ने आपकी ट्रिप स्वीकार की।`,
  yourDriver: "आपका ड्राइवर",
  arrivedTitle: "आपका ड्राइवर आ गया है",
  arrivedBody: "कृपया पिकअप जगह पर अपने ड्राइवर से मिलें।",
  completedTitle: "ट्रिप पूरी हुई",
  completedBody: "कृपया अपने ड्राइवर को रेटिंग दें। धन्यवाद!",
  cancelledTitle: "ट्रिप रद्द हुई",
  cancelledByCustomer: "ग्राहक ने यह ट्रिप रद्द कर दी।",
  cancelledByDriver: "आपके ड्राइवर ने रद्द किया। कृपया दूसरा ड्राइवर चुनें।",
};

const ALL: Record<Lang, Texts> = { en, te, hi };

export function msg(lang: string | null | undefined): Texts {
  return ALL[(lang as Lang) ?? "en"] ?? en;
}
